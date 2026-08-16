// kn_world.cpp — model construction, compilation, the step pipeline, collision
// bookkeeping, integration, sensors and scene queries.

#include "kn_world.hpp"

#include "kn_threads.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>

namespace kn {

namespace {

// Deterministic PRNG for sensor noise. Sensor readings must be reproducible
// across runs, so this never touches a global generator.
struct Xoroshiro {
    uint64_t s0 = 0x853c49e6748fea9bULL, s1 = 0xda3e39cb94b95bdbULL;
    uint64_t next() {
        uint64_t x = s0, y = s1;
        uint64_t result = x + y;
        y ^= x;
        s0 = ((x << 55) | (x >> 9)) ^ y ^ (y << 14);
        s1 = (y << 36) | (y >> 28);
        return result;
    }
    double uniform() { return double(next() >> 11) * (1.0 / 9007199254740992.0); }
    double gaussian() {
        double u1 = std::max(uniform(), 1e-12), u2 = uniform();
        return std::sqrt(-2.0 * std::log(u1)) * std::cos(2.0 * kPi * u2);
    }
};

Xoroshiro g_noise;

using Clock = std::chrono::steady_clock;
double elapsedMs(Clock::time_point a, Clock::time_point b) {
    return std::chrono::duration<double, std::milli>(b - a).count();
}

int sensorDim(SensorType t) {
    switch (t) {
        case SensorType::JointPosition:
        case SensorType::JointVelocity:
        case SensorType::ActuatorForce:
        case SensorType::ContactNormalForce:
        case SensorType::Rangefinder: return 1;
        case SensorType::IMUAccelerometer:
        case SensorType::IMUGyroscope:
        case SensorType::FramePosition:
        case SensorType::FrameLinearVelocity: return 3;
        case SensorType::FrameOrientation: return 4;
        case SensorType::ForceTorque: return 6;
    }
    return 1;
}

}  // namespace

World::World() = default;
World::~World() = default;

// ─────────────────────────────────────────────────── model construction ──

int World::addArticulation(const std::string &name) {
    compiled_ = false;
    Articulation a;
    a.name = name;
    articulations_.push_back(std::move(a));
    defaultPose_.emplace_back();
    return int(articulations_.size()) - 1;
}

int World::addLink(int articulation, int parent, const std::string &name) {
    compiled_ = false;
    Articulation &art = articulations_[articulation];
    Link l;
    l.name = name;
    l.parent = parent;
    art.links.push_back(std::move(l));
    return int(art.links.size()) - 1;
}

void World::setLinkInertial(int art, int link, Scalar mass, const Vec3 &com, const Mat3 &inertia) {
    compiled_ = false;
    Link &l = articulations_[art].links[link];
    l.mass = mass;
    l.com = com;
    l.inertia = inertia;
}

void World::setJoint(int art, int link, const Joint &joint) {
    compiled_ = false;
    articulations_[art].links[link].joint = joint;
}

int World::addGeom(int art, int link, const Geom &geom) {
    compiled_ = false;
    Geom g = geom;
    g.articulation = art;
    g.link = link;
    g.index = int(geoms_.size());
    geoms_.push_back(g);
    articulations_[art].links[link].geoms.push_back(g.index);
    return g.index;
}

int World::addMesh(const Mesh &mesh) {
    Mesh m = mesh;
    m.computeBounds();
    meshes_.push_back(std::move(m));
    return int(meshes_.size()) - 1;
}

int World::addActuator(const Actuator &actuator) {
    compiled_ = false;
    actuators_.push_back(actuator);
    return int(actuators_.size()) - 1;
}

int World::addSensor(const Sensor &sensor) {
    compiled_ = false;
    sensors_.push_back(sensor);
    return int(sensors_.size()) - 1;
}

int World::addEquality(const Equality &eq) {
    equalities_.push_back(eq);
    return int(equalities_.size()) - 1;
}

void World::compile() {
    nq_ = 0;
    nv_ = 0;
    linkCount_ = 0;
    linkOffset_.assign(articulations_.size(), 0);

    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        Articulation &art = articulations_[ai];
        art.qOffset = nq_;
        art.vOffset = nv_;
        int q = 0, v = 0;
        for (Link &l : art.links) {
            l.children.clear();
            Joint &j = l.joint;
            j.nq = jointCoordCount(j.type);
            j.nv = jointDofCount(j.type);
            j.qIndex = q;
            j.vIndex = v;
            q += j.nq;
            v += j.nv;
            if (j.axis.normSquared() > kEps) j.axis = j.axis.normalized();
        }
        for (size_t li = 0; li < art.links.size(); ++li)
            if (art.links[li].parent >= 0) art.links[art.links[li].parent].children.push_back(int(li));

        art.nq = q;
        art.nv = v;
        nq_ += q;
        nv_ += v;

        linkOffset_[ai] = linkCount_;
        linkCount_ += int(art.links.size());
    }

    caches_.resize(articulations_.size());
    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        Articulation &art = articulations_[ai];
        ArticulationCache &c = caches_[ai];
        c.massMatrix.resize(art.nv, art.nv);
        c.massMatrixRaw.resize(art.nv, art.nv);
        c.bias.assign(art.nv, 0);
        c.accelFree.assign(art.nv, 0);
        c.force.assign(art.nv, 0);
        c.subspace.assign(art.nv, SpatialVec::zero());
        c.dofLink.assign(art.nv, 0);
        c.composite.resize(art.links.size());
        c.accel.resize(art.links.size());
        c.netForce.resize(art.links.size());
        for (size_t li = 0; li < art.links.size(); ++li) {
            const Joint &j = art.links[li].joint;
            for (int k = 0; k < j.nv; ++k) c.dofLink[j.vIndex + k] = int(li);
        }
    }

    // Resolve actuator target dofs.
    for (Actuator &a : actuators_) {
        const Articulation &art = articulations_[a.articulation];
        a.dof = art.vOffset + art.links[a.link].joint.vIndex;
    }

    // Sensor layout.
    nsensor_ = 0;
    for (Sensor &s : sensors_) {
        s.dim = sensorDim(s.type);
        s.offset = nsensor_;
        nsensor_ += s.dim;
    }

    qpos.assign(nq_, 0);
    qvel.assign(nv_, 0);
    qacc.assign(nv_, 0);
    qfrcApplied.assign(nv_, 0);
    ctrl.assign(actuators_.size(), 0);
    actuatorForce.assign(actuators_.size(), 0);
    sensorData.assign(nsensor_, 0);
    xfrcApplied.assign(linkCount_, SpatialVec::zero());
    geomPose_.assign(geoms_.size(), Transform::identity());
    aabbs_.assign(geoms_.size(), AABB{});
    velPredicted_.assign(nv_, 0);
    deltaVel_.assign(nv_, 0);
    scratchNv_.assign(nv_, 0);

    compiled_ = true;
    resetState();
}

void World::resetState() {
    std::fill(qvel.begin(), qvel.end(), Scalar(0));
    std::fill(qacc.begin(), qacc.end(), Scalar(0));
    std::fill(qfrcApplied.begin(), qfrcApplied.end(), Scalar(0));
    std::fill(sensorData.begin(), sensorData.end(), Scalar(0));
    std::fill(xfrcApplied.begin(), xfrcApplied.end(), SpatialVec::zero());
    time = 0;
    manifoldCache_.clear();
    manifolds_.clear();
    contactForces_.clear();

    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        const Articulation &art = articulations_[ai];
        for (const Link &l : art.links) {
            const Joint &j = l.joint;
            Scalar *q = qpos.data() + art.qOffset + j.qIndex;
            switch (j.type) {
                case JointType::Fixed: break;
                case JointType::Revolute:
                case JointType::Prismatic: q[0] = 0; break;
                case JointType::Spherical:
                    q[0] = 1; q[1] = q[2] = q[3] = 0;
                    break;
                case JointType::Free:
                    q[0] = q[1] = q[2] = 0;
                    q[3] = 1; q[4] = q[5] = q[6] = 0;
                    break;
            }
        }
        const VecX &pose = defaultPose_[ai];
        if (int(pose.size()) == art.nq)
            for (int k = 0; k < art.nq; ++k) qpos[art.qOffset + k] = pose[k];
    }
    forwardKinematics();
}

void World::setDefaultPose(int art, const VecX &q) { defaultPose_[art] = q; }

void World::applyForceAtPoint(int art, int link, const Vec3 &force, const Vec3 &worldPoint) {
    int gi = linkGlobalIndex(art, link);
    xfrcApplied[gi].lin += force;
    xfrcApplied[gi].ang += worldPoint.cross(force);
}

void World::applyTorque(int art, int link, const Vec3 &torque) {
    xfrcApplied[linkGlobalIndex(art, link)].ang += torque;
}

void World::clearAppliedForces() {
    std::fill(xfrcApplied.begin(), xfrcApplied.end(), SpatialVec::zero());
    std::fill(qfrcApplied.begin(), qfrcApplied.end(), Scalar(0));
}

// ───────────────────────────────────────────────────────────── collision ──

void World::collide() {
    manifolds_.clear();
    if (!options.enableContacts) return;

    const Scalar h = options.timestep;
    for (size_t gi = 0; gi < geoms_.size(); ++gi) {
        const Geom &g = geoms_[gi];
        const Link &link = articulations_[g.articulation].links[g.link];
        geomPose_[gi] = link.pose * g.localPose;
        if (!g.collidable) {
            aabbs_[gi].min = Vec3(1, 1, 1);
            aabbs_[gi].max = Vec3(0, 0, 0);  // marks the geom as skipped
            continue;
        }
        aabbs_[gi] = geomAABB(g, geomPose_[gi], meshes_);
        aabbs_[gi].grow(options.contactMargin + g.material.margin);
        // Extend the bound along this step's motion — directionally, not
        // isotropically — so a fast body still finds the surface it is about to
        // hit without inflating the broadphase for everything around it. The
        // speculative contact built from that pair then stops the body exactly
        // at the surface instead of letting it tunnel through.
        Vec3 motion = link.velocity.pointVelocity(geomPose_[gi].pos) * h;
        if (motion.normSquared() > 1e-12) {
            for (int axis = 0; axis < 3; ++axis) {
                Scalar d = clampf(motion[axis], -2.0, 2.0);
                if (d < 0) aabbs_[gi].min[axis] += d; else aabbs_[gi].max[axis] += d;
            }
        }
    }

    broadphase_.update(aabbs_);
    profile_.broadphasePairs = int(broadphase_.pairs().size());

    // Approach speed decides how far ahead a pair must look: only geoms that
    // are actually closing fast pay for a wide search band, so a settled scene
    // keeps the tight default margin.
    auto speculativeMargin = [&](int a, int b) {
        const Geom &ga = geoms_[a];
        const Geom &gb = geoms_[b];
        Scalar base = options.contactMargin + std::max(ga.material.margin, gb.material.margin);
        const Link &la = articulations_[ga.articulation].links[ga.link];
        const Link &lb = articulations_[gb.articulation].links[gb.link];
        Vec3 relative = la.velocity.pointVelocity(geomPose_[a].pos)
                      - lb.velocity.pointVelocity(geomPose_[b].pos);
        Scalar sweep = std::min(relative.norm() * h, Scalar(2.0));
        return base + sweep;
    };

    // ── filter (serial, cheap) ────────────────────────────────────────
    candidatePairs_.clear();
    for (const auto &pr : broadphase_.pairs()) {
        const Geom &ga = geoms_[pr.first];
        const Geom &gb = geoms_[pr.second];

        if (!ga.collidable || !gb.collidable) continue;
        if (!(ga.group & gb.mask) || !(gb.group & ga.mask)) continue;
        if (ga.articulation == gb.articulation) {
            const Articulation &art = articulations_[ga.articulation];
            if (ga.link == gb.link) continue;
            if (!art.selfCollision) continue;
            // Adjacent links share a joint and always interpenetrate slightly.
            if (art.links[ga.link].parent == gb.link || art.links[gb.link].parent == ga.link)
                continue;
        }
        if (articulations_[ga.articulation].nv == 0 && articulations_[gb.articulation].nv == 0)
            continue;
        if (!articulations_[ga.articulation].enabled || !articulations_[gb.articulation].enabled)
            continue;
        candidatePairs_.push_back(pr);
    }

    // ── narrowphase (parallel, results indexed by candidate) ──────────
    narrowphaseResults_.assign(candidatePairs_.size(), NarrowphaseResult{});
    auto narrowphase = [&](int index) {
        const auto &pr = candidatePairs_[index];
        const Geom &ga = geoms_[pr.first];
        const Geom &gb = geoms_[pr.second];
        NarrowphaseResult &out = narrowphaseResults_[index];
        out.margin = speculativeMargin(pr.first, pr.second);
        out.count = collidePair(ga, geomPose_[pr.first], gb, geomPose_[pr.second], meshes_,
                                out.margin, out.points, 4, &out.persistent);
    };
    if (options.multithreaded && candidatePairs_.size() >= 24) {
        ThreadPool::shared().parallelFor(int(candidatePairs_.size()), 8, narrowphase);
    } else {
        for (int i = 0; i < int(candidatePairs_.size()); ++i) narrowphase(i);
    }

    // ── merge with the previous step's manifolds (serial, ordered) ────
    std::unordered_map<uint64_t, Manifold> next;
    next.reserve(candidatePairs_.size());

    for (size_t index = 0; index < candidatePairs_.size(); ++index) {
        const auto &pr = candidatePairs_[index];
        const Geom &ga = geoms_[pr.first];
        const Geom &gb = geoms_[pr.second];
        const int count = narrowphaseResults_[index].count;
        const bool persistent = narrowphaseResults_[index].persistent;
        const ContactPoint *newPoints = narrowphaseResults_[index].points;
        if (count == 0) continue;

        uint64_t key = manifoldKey(pr.first, pr.second);
        auto oldIt = manifoldCache_.find(key);
        const Scalar margin = narrowphaseResults_[index].margin;

        Manifold man;
        man.geomA = pr.first;
        man.geomB = pr.second;
        man.artA = ga.articulation;
        man.linkA = ga.link;
        man.artB = gb.articulation;
        man.linkB = gb.link;
        man.friction = std::sqrt(ga.material.friction * gb.material.friction);
        man.torsionalFriction =
            std::sqrt(ga.material.torsionalFriction * gb.material.torsionalFriction);
        man.restitution = std::max(ga.material.restitution, gb.material.restitution);
        man.timeConst = std::max(ga.material.stiffnessTimeConst, gb.material.stiffnessTimeConst);
        man.dampingRatio = std::max(ga.material.dampingRatio, gb.material.dampingRatio);

        if (persistent && oldIt != manifoldCache_.end()) {
            // Carry forward previous points, re-anchored to the current poses.
            const Manifold &old = oldIt->second;
            for (int i = 0; i < old.count; ++i) {
                ContactPoint p = old.points[i];
                Vec3 wa = geomPose_[pr.first].apply(p.localA);
                Vec3 wb = geomPose_[pr.second].apply(p.localB);
                Vec3 d = wa - wb;
                Scalar normalDist = d.dot(p.normal);
                Vec3 tangential = d - p.normal * normalDist;
                if (-normalDist > margin) continue;              // separated
                if (tangential.norm() > 0.01) continue;          // slid too far
                p.depth = -normalDist;
                p.position = (wa + wb) * Scalar(0.5);
                p.fresh = false;
                man.addPoint(p);
            }
            for (int i = 0; i < count; ++i) {
                bool merged = false;
                for (int j = 0; j < man.count; ++j) {
                    if ((man.points[j].position - newPoints[i].position).norm() < 0.005) {
                        Scalar in = man.points[j].impulseNormal;
                        Scalar t1 = man.points[j].impulseT1, t2 = man.points[j].impulseT2;
                        man.points[j] = newPoints[i];
                        man.points[j].impulseNormal = in;
                        man.points[j].impulseT1 = t1;
                        man.points[j].impulseT2 = t2;
                        merged = true;
                        break;
                    }
                }
                if (!merged) man.addPoint(newPoints[i]);
            }
        } else {
            for (int i = 0; i < count; ++i) {
                ContactPoint p = newPoints[i];
                if (oldIt != manifoldCache_.end()) {
                    // Warm start from the nearest previous point.
                    const Manifold &old = oldIt->second;
                    Scalar best = 1e30;
                    int bestIdx = -1;
                    for (int j = 0; j < old.count; ++j) {
                        Scalar d = (old.points[j].localA - p.localA).norm();
                        if (d < best) {
                            best = d;
                            bestIdx = j;
                        }
                    }
                    if (bestIdx >= 0 && best < 0.02) {
                        p.impulseNormal = old.points[bestIdx].impulseNormal;
                        p.impulseT1 = old.points[bestIdx].impulseT1;
                        p.impulseT2 = old.points[bestIdx].impulseT2;
                    }
                }
                man.addPoint(p);
            }
        }

        if (man.count > 0) {
            next[key] = man;
            manifolds_.push_back(man);
        }
    }

    manifoldCache_.swap(next);
    int total = 0;
    for (const Manifold &m : manifolds_) total += m.count;
    profile_.contactCount = total;
}

// ──────────────────────────────────────────────────────────── integrate ──

void World::integratePositions(Scalar h, const VecX &vel) {
    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        Articulation &art = articulations_[ai];
        for (size_t li = 0; li < art.links.size(); ++li) {
            Link &l = art.links[li];
            const Joint &j = l.joint;
            if (j.nv == 0) continue;
            Scalar *q = qpos.data() + art.qOffset + j.qIndex;
            const Scalar *v = vel.data() + art.vOffset + j.vIndex;

            Transform parentPose =
                l.parent >= 0 ? art.links[l.parent].pose : Transform::identity();
            Quat jointRot = (parentPose * j.origin).rot;

            switch (j.type) {
                case JointType::Fixed: break;
                case JointType::Revolute:
                case JointType::Prismatic:
                    q[0] += h * v[0];
                    if (j.limited) q[0] = clampf(q[0], j.lower, j.upper);
                    break;
                case JointType::Spherical: {
                    Vec3 omegaLocal = jointRot.inverseRotate(Vec3(v[0], v[1], v[2]));
                    Quat cur(q[0], q[1], q[2], q[3]);
                    Quat next = (Quat::fromRotationVector(omegaLocal * h) * cur).normalized();
                    q[0] = next.w; q[1] = next.x; q[2] = next.y; q[3] = next.z;
                    break;
                }
                case JointType::Free: {
                    Vec3 vLocal = jointRot.inverseRotate(Vec3(v[0], v[1], v[2]));
                    Vec3 omegaLocal = jointRot.inverseRotate(Vec3(v[3], v[4], v[5]));
                    q[0] += h * vLocal.x;
                    q[1] += h * vLocal.y;
                    q[2] += h * vLocal.z;
                    Quat cur(q[3], q[4], q[5], q[6]);
                    Quat next = (Quat::fromRotationVector(omegaLocal * h) * cur).normalized();
                    q[3] = next.w; q[4] = next.x; q[5] = next.y; q[6] = next.z;
                    break;
                }
            }
        }
    }
}

// Re-runs the smooth half of the pipeline at the current (qpos, qvel) and
// writes the unconstrained acceleration into `accelOut`.
void World::evaluateSmoothAcceleration(VecX &accelOut) {
    forwardKinematics();
    compositeRigidBodyInertia();
    inverseDynamicsBias();
    applyForces();
    factorMass();
    unconstrainedAcceleration();
    accelOut.assign(nv_, 0);
    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        const Articulation &art = articulations_[ai];
        for (int k = 0; k < art.nv; ++k)
            accelOut[art.vOffset + k] = caches_[ai].accelFree[k];
    }
}

// Classical fourth-order Runge-Kutta over the smooth dynamics. Position updates
// go through integratePositions(), so quaternions stay on the manifold at every
// stage. Only used when no constraint is active this step: constraint impulses
// are not differentiable, and evaluating them at intermediate stages would cost
// four solves for a result no more accurate than the first-order update.
void World::integrateRK4(Scalar h) {
    VecX q0 = qpos, v0 = qvel;
    VecX a1, a2, a3, a4;

    evaluateSmoothAcceleration(a1);

    // Stage 2 at t + h/2.
    VecX v1(nv_);
    for (int k = 0; k < nv_; ++k) v1[k] = v0[k] + Scalar(0.5) * h * a1[k];
    qpos = q0;
    forwardKinematics();
    integratePositions(h * Scalar(0.5), v0);
    qvel = v1;
    evaluateSmoothAcceleration(a2);

    // Stage 3 at t + h/2.
    VecX v2(nv_);
    for (int k = 0; k < nv_; ++k) v2[k] = v0[k] + Scalar(0.5) * h * a2[k];
    qpos = q0;
    forwardKinematics();
    integratePositions(h * Scalar(0.5), v1);
    qvel = v2;
    evaluateSmoothAcceleration(a3);

    // Stage 4 at t + h.
    VecX v3(nv_);
    for (int k = 0; k < nv_; ++k) v3[k] = v0[k] + h * a3[k];
    qpos = q0;
    forwardKinematics();
    integratePositions(h, v2);
    qvel = v3;
    evaluateSmoothAcceleration(a4);

    VecX vAvg(nv_), aAvg(nv_);
    for (int k = 0; k < nv_; ++k) {
        aAvg[k] = (a1[k] + 2 * a2[k] + 2 * a3[k] + a4[k]) / Scalar(6);
        vAvg[k] = (v0[k] + 2 * v1[k] + 2 * v2[k] + v3[k]) / Scalar(6);
    }

    qpos = q0;
    qvel = v0;
    forwardKinematics();
    integratePositions(h, vAvg);
    for (int k = 0; k < nv_; ++k) {
        Scalar v = v0[k] + h * aAvg[k];
        qvel[k] = std::isfinite(v) ? clampf(v, -options.maxVelocity, options.maxVelocity) : 0;
        qacc[k] = aAvg[k];
    }
}

void World::integrate(Scalar h) {
    for (int k = 0; k < nv_; ++k) {
        Scalar v = qvel[k] + h * qacc[k];
        if (!std::isfinite(v)) v = 0;
        qvel[k] = clampf(v, -options.maxVelocity, options.maxVelocity);
    }

    if (options.linearDamping > 0 || options.angularDamping > 0) {
        for (const Articulation &art : articulations_)
            for (const Link &l : art.links) {
                const Joint &j = l.joint;
                if (j.type == JointType::Free) {
                    Scalar kl = std::max(Scalar(0), 1 - options.linearDamping * h);
                    Scalar ka = std::max(Scalar(0), 1 - options.angularDamping * h);
                    for (int k = 0; k < 3; ++k) qvel[art.vOffset + j.vIndex + k] *= kl;
                    for (int k = 3; k < 6; ++k) qvel[art.vOffset + j.vIndex + k] *= ka;
                }
            }
    }

    integratePositions(h, qvel);
}

// ────────────────────────────────────────────────────────────────── step ──

void World::forward() {
    forwardKinematics();
    compositeRigidBodyInertia();
    inverseDynamicsBias();
    applyForces();
    factorMass();
    unconstrainedAcceleration();
    computeSensors();
}

void World::step() {
    if (!compiled_) compile();
    auto t0 = Clock::now();

    forwardKinematics();
    auto t1 = Clock::now();

    compositeRigidBodyInertia();
    auto t2 = Clock::now();

    inverseDynamicsBias();
    applyForces();
    factorMass();
    unconstrainedAcceleration();
    auto t3 = Clock::now();

    collide();
    auto t4 = Clock::now();

    buildConstraints();
    auto t5 = Clock::now();

    solveConstraints();
    auto t6 = Clock::now();

    // RK4 buys accuracy only while the dynamics stay smooth; the moment a
    // constraint is active the step falls back to the first-order update.
    if (options.integrator == Integrator::RK4 && profile_.constraintCount == 0) {
        integrateRK4(options.timestep);
    } else {
        integrate(options.timestep);
    }
    time += options.timestep;
    auto t7 = Clock::now();

    forwardKinematics();
    computeSensors();
    auto t8 = Clock::now();

    // Persist impulses for the next step's warm start.
    for (const Manifold &m : manifolds_) manifoldCache_[manifoldKey(m.geomA, m.geomB)] = m;

    profile_.kinematics = elapsedMs(t0, t1);
    profile_.inertia = elapsedMs(t1, t2);
    profile_.bias = elapsedMs(t2, t3);
    profile_.collision = elapsedMs(t3, t4);
    profile_.constraintSetup = elapsedMs(t4, t5);
    profile_.solve = elapsedMs(t5, t6);
    profile_.integrate = elapsedMs(t6, t7);
    profile_.sensors = elapsedMs(t7, t8);
    profile_.total = elapsedMs(t0, t8);
}

void World::stepMany(int count) {
    for (int i = 0; i < count; ++i) step();
}

// ───────────────────────────────────────────────────────────── sensors ──

void World::computeSensors() {
    if (sensors_.empty()) return;

    // Full link accelerations, including the solved qacc.
    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        Articulation &art = articulations_[ai];
        ArticulationCache &cache = caches_[ai];
        if (art.nv == 0) {
            for (auto &a : cache.accel) a = SpatialVec(Vec3::zero(), -options.gravity);
            continue;
        }
        const SpatialVec a0(Vec3::zero(), -options.gravity);
        for (size_t li = 0; li < art.links.size(); ++li) {
            const Link &l = art.links[li];
            const Joint &j = l.joint;
            SpatialVec a = l.parent >= 0 ? cache.accel[l.parent] : a0;
            for (int k = 0; k < j.nv; ++k) {
                int dof = j.vIndex + k;
                a += cache.subspace[dof] * qacc[art.vOffset + dof];
                Scalar qd = qvel[art.vOffset + dof];
                if (qd != 0) a += crossMotion(l.velocity, cache.subspace[dof]) * qd;
            }
            cache.accel[li] = a;
        }
    }

    for (const Sensor &s : sensors_) {
        const Articulation &art = articulations_[s.articulation];
        const Link &l = art.links[s.link];
        Scalar *out = sensorData.data() + s.offset;
        Transform site = l.pose * s.localPose;

        switch (s.type) {
            case SensorType::JointPosition:
                out[0] = qpos[art.qOffset + l.joint.qIndex];
                break;
            case SensorType::JointVelocity:
                out[0] = qvel[art.vOffset + l.joint.vIndex];
                break;
            case SensorType::ActuatorForce:
                out[0] = (s.dof >= 0 && s.dof < int(actuatorForce.size())) ? actuatorForce[s.dof] : 0;
                break;
            case SensorType::IMUGyroscope: {
                Vec3 w = site.rot.inverseRotate(l.velocity.ang);
                out[0] = w.x; out[1] = w.y; out[2] = w.z;
                break;
            }
            case SensorType::IMUAccelerometer: {
                const SpatialVec &a = caches_[s.articulation].accel[s.link];
                Vec3 p = site.pos;
                Vec3 vP = l.velocity.pointVelocity(p);
                Vec3 aP = a.lin + a.ang.cross(p) + l.velocity.ang.cross(vP);
                Vec3 local = site.rot.inverseRotate(aP);
                out[0] = local.x; out[1] = local.y; out[2] = local.z;
                break;
            }
            case SensorType::FramePosition:
                out[0] = site.pos.x; out[1] = site.pos.y; out[2] = site.pos.z;
                break;
            case SensorType::FrameOrientation:
                out[0] = site.rot.w; out[1] = site.rot.x; out[2] = site.rot.y; out[3] = site.rot.z;
                break;
            case SensorType::FrameLinearVelocity: {
                Vec3 v = l.velocity.pointVelocity(site.pos);
                out[0] = v.x; out[1] = v.y; out[2] = v.z;
                break;
            }
            case SensorType::ForceTorque: {
                Vec3 force = Vec3::zero(), torque = Vec3::zero();
                for (const ContactForceRecord &c : contactForces_) {
                    const Geom &ga = geoms_[c.geomA];
                    const Geom &gb = geoms_[c.geomB];
                    Scalar sign = 0;
                    if (ga.articulation == s.articulation && ga.link == s.link) sign = 1;
                    else if (gb.articulation == s.articulation && gb.link == s.link) sign = -1;
                    else continue;
                    Vec3 f = c.force * sign;
                    force += f;
                    torque += (c.point - site.pos).cross(f);
                }
                Vec3 fl = site.rot.inverseRotate(force);
                Vec3 tl = site.rot.inverseRotate(torque);
                out[0] = fl.x; out[1] = fl.y; out[2] = fl.z;
                out[3] = tl.x; out[4] = tl.y; out[5] = tl.z;
                break;
            }
            case SensorType::ContactNormalForce: {
                Scalar sum = 0;
                for (const ContactForceRecord &c : contactForces_) {
                    const Geom &ga = geoms_[c.geomA];
                    const Geom &gb = geoms_[c.geomB];
                    if ((ga.articulation == s.articulation && ga.link == s.link) ||
                        (gb.articulation == s.articulation && gb.link == s.link))
                        sum += c.force.dot(c.normal);
                }
                out[0] = sum;
                break;
            }
            case SensorType::Rangefinder: {
                Vec3 dir = site.applyVector(Vec3::unitZ());
                RayHit hit = raycast(site.pos, dir, s.cutoff > 0 ? s.cutoff : 100.0, 0xFFFFFFFFu,
                                     s.articulation);
                out[0] = hit.hit ? hit.distance : -1;
                break;
            }
        }

        if (s.noiseStdDev > 0)
            for (int k = 0; k < s.dim; ++k) out[k] += Scalar(g_noise.gaussian()) * s.noiseStdDev;
        if (s.bias != 0)
            for (int k = 0; k < s.dim; ++k) out[k] += s.bias;
        if (s.cutoff > 0 && s.type != SensorType::Rangefinder)
            for (int k = 0; k < s.dim; ++k) out[k] = clampf(out[k], -s.cutoff, s.cutoff);
    }
}

// ───────────────────────────────────────────────────────────── queries ──

RayHit World::raycast(const Vec3 &origin, const Vec3 &dir, Scalar maxDist, uint32_t mask,
                      int ignoreArticulation) const {
    RayHit best;
    best.distance = maxDist;
    Vec3 d = dir.normalized();
    for (size_t gi = 0; gi < geoms_.size(); ++gi) {
        const Geom &g = geoms_[gi];
        if (!g.collidable) continue;
        if (!(g.group & mask)) continue;
        if (g.articulation == ignoreArticulation) continue;
        Transform pose = articulations_[g.articulation].links[g.link].pose * g.localPose;
        Scalar t;
        Vec3 n;
        if (rayGeom(g, pose, meshes_, origin, d, best.distance, t, n)) {
            if (t < best.distance || !best.hit) {
                best.hit = true;
                best.distance = t;
                best.point = origin + d * t;
                best.normal = n;
                best.geom = int(gi);
                best.articulation = g.articulation;
                best.link = g.link;
            }
        }
    }
    if (!best.hit) best.distance = 0;
    return best;
}

int World::findArticulation(const std::string &name) const {
    for (size_t i = 0; i < articulations_.size(); ++i)
        if (articulations_[i].name == name) return int(i);
    return -1;
}

int World::findLink(int art, const std::string &name) const {
    if (art < 0 || art >= int(articulations_.size())) return -1;
    const auto &links = articulations_[art].links;
    for (size_t i = 0; i < links.size(); ++i)
        if (links[i].name == name) return int(i);
    return -1;
}

int World::findGeom(const std::string &name) const {
    for (size_t i = 0; i < geoms_.size(); ++i)
        if (geoms_[i].name == name) return int(i);
    return -1;
}

int World::findActuator(const std::string &name) const {
    for (size_t i = 0; i < actuators_.size(); ++i)
        if (actuators_[i].name == name) return int(i);
    return -1;
}

void World::saveState(VecX &out) const {
    out.clear();
    out.reserve(nq_ + nv_ + 1);
    out.insert(out.end(), qpos.begin(), qpos.end());
    out.insert(out.end(), qvel.begin(), qvel.end());
    out.push_back(time);
}

void World::loadState(const VecX &in) {
    if (int(in.size()) < nq_ + nv_ + 1) return;
    std::copy(in.begin(), in.begin() + nq_, qpos.begin());
    std::copy(in.begin() + nq_, in.begin() + nq_ + nv_, qvel.begin());
    time = in[nq_ + nv_];
    manifoldCache_.clear();
    forwardKinematics();
}

}  // namespace kn
