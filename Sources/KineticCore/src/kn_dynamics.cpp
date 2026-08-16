// kn_dynamics.cpp — forward kinematics, motion subspaces, CRBA, RNEA and the
// mass-matrix factorisation.
//
// All spatial quantities live in the world frame (see kn_spatial.hpp). Links
// within an articulation are stored parent-before-child, which compile()
// enforces, so every recursion here is a plain forward or reverse loop.

#include "kn_math.hpp"
#include "kn_model.hpp"
#include "kn_spatial.hpp"
#include "kn_world.hpp"

namespace kn {

void World::forwardKinematics() {
    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        Articulation &art = articulations_[ai];
        ArticulationCache &cache = caches_[ai];
        const int qBase = art.qOffset;
        const int vBase = art.vOffset;

        for (size_t li = 0; li < art.links.size(); ++li) {
            Link &link = art.links[li];
            const Joint &jnt = link.joint;
            Transform parentPose =
                link.parent >= 0 ? art.links[link.parent].pose : Transform::identity();
            Transform jointFrame = parentPose * jnt.origin;
            link.jointAnchor = jointFrame.pos;

            const Scalar *q = qpos.data() + qBase + jnt.qIndex;
            switch (jnt.type) {
                case JointType::Fixed:
                    link.pose = jointFrame;
                    break;
                case JointType::Revolute:
                    link.pose = jointFrame * Transform(Quat::fromAxisAngle(jnt.axis, q[0]),
                                                       Vec3::zero());
                    break;
                case JointType::Prismatic:
                    link.pose = jointFrame * Transform(Quat::identity(), jnt.axis * q[0]);
                    break;
                case JointType::Spherical: {
                    Quat rot(q[0], q[1], q[2], q[3]);
                    link.pose = jointFrame * Transform(rot.normalized(), Vec3::zero());
                    break;
                }
                case JointType::Free: {
                    Quat rot(q[3], q[4], q[5], q[6]);
                    link.pose = jointFrame * Transform(rot.normalized(), Vec3(q[0], q[1], q[2]));
                    break;
                }
            }

            Mat3 R = link.pose.rot.toMatrix();
            link.worldCom = link.pose.apply(link.com);
            link.spatialInertia =
                SpatialInertia::fromComInertia(link.mass, link.worldCom, rotateInertia(R, link.inertia));
        }

        // Motion subspaces, then link spatial velocities.
        for (size_t li = 0; li < art.links.size(); ++li) {
            Link &link = art.links[li];
            const Joint &jnt = link.joint;
            const int v0 = jnt.vIndex;
            const Vec3 anchor = link.jointAnchor;

            switch (jnt.type) {
                case JointType::Fixed:
                    break;
                case JointType::Revolute: {
                    Vec3 a = (link.parent >= 0 ? art.links[link.parent].pose : Transform::identity())
                                 .applyVector(jnt.origin.applyVector(jnt.axis))
                                 .normalized();
                    cache.subspace[v0] = SpatialVec(a, anchor.cross(a));
                    break;
                }
                case JointType::Prismatic: {
                    Vec3 a = (link.parent >= 0 ? art.links[link.parent].pose : Transform::identity())
                                 .applyVector(jnt.origin.applyVector(jnt.axis))
                                 .normalized();
                    cache.subspace[v0] = SpatialVec(Vec3::zero(), a);
                    break;
                }
                case JointType::Spherical: {
                    for (int k = 0; k < 3; ++k) {
                        Vec3 e = Vec3::zero();
                        e[k] = 1;
                        cache.subspace[v0 + k] = SpatialVec(e, anchor.cross(e));
                    }
                    break;
                }
                case JointType::Free: {
                    Vec3 p = link.pose.pos;
                    for (int k = 0; k < 3; ++k) {
                        Vec3 e = Vec3::zero();
                        e[k] = 1;
                        cache.subspace[v0 + k] = SpatialVec(Vec3::zero(), e);       // linear
                        cache.subspace[v0 + 3 + k] = SpatialVec(e, p.cross(e));     // angular
                    }
                    break;
                }
            }

            SpatialVec v = link.parent >= 0 ? art.links[link.parent].velocity : SpatialVec::zero();
            for (int k = 0; k < jnt.nv; ++k) v += cache.subspace[v0 + k] * qvel[vBase + v0 + k];
            link.velocity = v;
        }
    }
}

void World::computeSubspace() {
    // Subspaces are produced as a side effect of forwardKinematics(); this hook
    // exists so callers can express intent at the call site.
    forwardKinematics();
}

void World::compositeRigidBodyInertia() {
    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        Articulation &art = articulations_[ai];
        ArticulationCache &cache = caches_[ai];
        const int n = art.nv;
        if (n == 0) continue;

        cache.composite.resize(art.links.size());
        for (size_t li = 0; li < art.links.size(); ++li)
            cache.composite[li] = art.links[li].spatialInertia;
        for (int li = int(art.links.size()) - 1; li >= 1; --li) {
            int p = art.links[li].parent;
            if (p >= 0) cache.composite[p] += cache.composite[li];
        }

        MatX &M = cache.massMatrixRaw;
        M.setZero();

        for (int li = int(art.links.size()) - 1; li >= 0; --li) {
            const Link &link = art.links[li];
            const Joint &jnt = link.joint;
            for (int a = 0; a < jnt.nv; ++a) {
                int rowDof = jnt.vIndex + a;
                SpatialVec F = cache.composite[li] * cache.subspace[rowDof];

                // Same-joint block.
                for (int b = 0; b < jnt.nv; ++b) {
                    int colDof = jnt.vIndex + b;
                    Scalar val = F.dot(cache.subspace[colDof]);
                    M(rowDof, colDof) = val;
                }
                // Ancestor blocks.
                int j = link.parent;
                while (j >= 0) {
                    const Joint &pj = art.links[j].joint;
                    for (int b = 0; b < pj.nv; ++b) {
                        int colDof = pj.vIndex + b;
                        Scalar val = F.dot(cache.subspace[colDof]);
                        M(rowDof, colDof) = val;
                        M(colDof, rowDof) = val;
                    }
                    j = art.links[j].parent;
                }
            }
        }

        // Rotor inertia sits on the diagonal.
        for (size_t li = 0; li < art.links.size(); ++li) {
            const Joint &jnt = art.links[li].joint;
            for (int a = 0; a < jnt.nv; ++a) M(jnt.vIndex + a, jnt.vIndex + a) += jnt.armature;
        }
    }
}

void World::inverseDynamicsBias() {
    const SpatialVec a0(Vec3::zero(), -options.gravity);

    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        Articulation &art = articulations_[ai];
        ArticulationCache &cache = caches_[ai];
        if (art.nv == 0) continue;

        cache.accel.resize(art.links.size());
        cache.netForce.resize(art.links.size());

        for (size_t li = 0; li < art.links.size(); ++li) {
            const Link &link = art.links[li];
            const Joint &jnt = link.joint;
            SpatialVec a = link.parent >= 0 ? cache.accel[link.parent] : a0;
            for (int k = 0; k < jnt.nv; ++k) {
                Scalar qd = qvel[art.vOffset + jnt.vIndex + k];
                if (qd != 0) a += crossMotion(link.velocity, cache.subspace[jnt.vIndex + k]) * qd;
            }
            cache.accel[li] = a;
            const SpatialInertia &I = link.spatialInertia;
            cache.netForce[li] = I * a + crossForce(link.velocity, I * link.velocity);
        }

        for (int li = int(art.links.size()) - 1; li >= 0; --li) {
            const Link &link = art.links[li];
            const Joint &jnt = link.joint;
            for (int k = 0; k < jnt.nv; ++k)
                cache.bias[jnt.vIndex + k] = cache.subspace[jnt.vIndex + k].dot(cache.netForce[li]);
            if (link.parent >= 0) cache.netForce[link.parent] += cache.netForce[li];
        }
    }
}

void World::applyForces() {
    // Reset the generalised force accumulator, then add:
    //   external link wrenches -> J^T f
    //   joint springs, dry-friction-free viscous damping
    //   actuators
    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        Articulation &art = articulations_[ai];
        ArticulationCache &cache = caches_[ai];
        if (art.nv == 0) continue;
        std::fill(cache.force.begin(), cache.force.end(), Scalar(0));

        for (size_t li = 0; li < art.links.size(); ++li) {
            const Link &link = art.links[li];
            const Joint &jnt = link.joint;
            for (int k = 0; k < jnt.nv; ++k) {
                int dof = jnt.vIndex + k;
                Scalar q = 0;
                if (jnt.type == JointType::Revolute || jnt.type == JointType::Prismatic)
                    q = qpos[art.qOffset + jnt.qIndex];
                Scalar qd = qvel[art.vOffset + dof];
                Scalar f = 0;
                if (jnt.stiffness != 0) f -= jnt.stiffness * (q - jnt.springRef);
                if (jnt.damping != 0) f -= jnt.damping * qd;
                cache.force[dof] += f;
            }
        }

        for (int k = 0; k < art.nv; ++k) cache.force[k] += qfrcApplied[art.vOffset + k];
    }

    // External link wrenches: tau += sum over the subtree of S^T f.
    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        Articulation &art = articulations_[ai];
        ArticulationCache &cache = caches_[ai];
        if (art.nv == 0) continue;
        bool any = false;
        for (size_t li = 0; li < art.links.size(); ++li) {
            const SpatialVec &f = xfrcApplied[linkGlobalIndex(int(ai), int(li))];
            if (f.ang.normSquared() > 0 || f.lin.normSquared() > 0) {
                any = true;
                break;
            }
        }
        if (!any) continue;
        std::vector<SpatialVec> acc(art.links.size(), SpatialVec::zero());
        for (size_t li = 0; li < art.links.size(); ++li)
            acc[li] = xfrcApplied[linkGlobalIndex(int(ai), int(li))];
        for (int li = int(art.links.size()) - 1; li >= 0; --li) {
            const Link &link = art.links[li];
            const Joint &jnt = link.joint;
            for (int k = 0; k < jnt.nv; ++k)
                cache.force[jnt.vIndex + k] += cache.subspace[jnt.vIndex + k].dot(acc[li]);
            if (link.parent >= 0) acc[link.parent] += acc[li];
        }
    }

    // Actuators.
    for (size_t i = 0; i < actuators_.size(); ++i) {
        const Actuator &act = actuators_[i];
        Articulation &art = articulations_[act.articulation];
        ArticulationCache &cache = caches_[act.articulation];
        if (art.nv == 0) continue;
        int localDof = act.dof - art.vOffset;
        if (localDof < 0 || localDof >= art.nv) continue;

        Scalar c = clampf(ctrl[i], act.ctrlMin, act.ctrlMax);
        const Link &link = art.links[act.link];
        const Joint &jnt = link.joint;
        Scalar q = (jnt.type == JointType::Revolute || jnt.type == JointType::Prismatic)
                       ? qpos[art.qOffset + jnt.qIndex]
                       : 0;
        Scalar qd = qvel[act.dof];

        Scalar f = 0;
        switch (act.type) {
            case ActuatorType::Motor: f = act.gear * c; break;
            case ActuatorType::Position: f = act.gear * (act.kp * (c - q) - act.kd * qd); break;
            case ActuatorType::Velocity: f = act.gear * (act.kp * (c - qd)); break;
            case ActuatorType::Damper: f = -act.gear * c * qd; break;
        }
        f = clampf(f, act.forceMin, act.forceMax);
        if (jnt.effortLimit > 0) f = clampf(f, -jnt.effortLimit, jnt.effortLimit);
        actuatorForce[i] = f;
        cache.force[localDof] += f;
    }
}

void World::factorMass() {
    const Scalar h = options.timestep;
    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        Articulation &art = articulations_[ai];
        ArticulationCache &cache = caches_[ai];
        if (art.nv == 0) continue;
        cache.massMatrix = cache.massMatrixRaw;

        // Implicit viscous terms: joint damping and actuator derivative gains
        // move to the left-hand side, which removes the usual stiffness limit
        // on how large kd can be for a given timestep.
        for (size_t li = 0; li < art.links.size(); ++li) {
            const Joint &jnt = art.links[li].joint;
            for (int k = 0; k < jnt.nv; ++k)
                cache.massMatrix(jnt.vIndex + k, jnt.vIndex + k) += h * jnt.damping;
        }
        for (size_t i = 0; i < actuators_.size(); ++i) {
            const Actuator &act = actuators_[i];
            if (act.articulation != int(ai)) continue;
            int d = act.dof - art.vOffset;
            if (d < 0 || d >= art.nv) continue;
            Scalar implicitGain = 0;
            if (act.type == ActuatorType::Position) implicitGain = act.gear * act.kd;
            if (act.type == ActuatorType::Velocity) implicitGain = act.gear * act.kp;
            if (implicitGain > 0) cache.massMatrix(d, d) += h * implicitGain;
        }

        cache.factorOK = ldltFactor(cache.massMatrix);
        if (!cache.factorOK) {
            // Regularise and retry once; a non-PD mass matrix means degenerate
            // inertial parameters, which we clamp rather than propagate.
            cache.massMatrix = cache.massMatrixRaw;
            for (int k = 0; k < art.nv; ++k) cache.massMatrix(k, k) += 1e-6;
            cache.factorOK = ldltFactor(cache.massMatrix, 1e-8);
        }
    }
}

void World::solveMassInverse(int art, const Scalar *rhs, Scalar *out) const {
    const ArticulationCache &cache = caches_[art];
    const int n = articulations_[art].nv;
    if (n == 0) return;
    for (int i = 0; i < n; ++i) out[i] = rhs[i];
    ldltSolveInPlace(cache.massMatrix, out);
}

void World::unconstrainedAcceleration() {
    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        Articulation &art = articulations_[ai];
        ArticulationCache &cache = caches_[ai];
        if (art.nv == 0) continue;
        VecX rhs(art.nv);
        for (int k = 0; k < art.nv; ++k) rhs[k] = cache.force[k] - cache.bias[k];
        solveMassInverse(int(ai), rhs.data(), cache.accelFree.data());
    }
}

void World::pointJacobian(int art, int link, const Vec3 &worldPoint, Scalar *out) const {
    const Articulation &a = articulations_[art];
    const ArticulationCache &cache = caches_[art];
    const int n = a.nv;
    for (int i = 0; i < 3 * n; ++i) out[i] = 0;

    int li = link;
    while (li >= 0) {
        const Joint &jnt = a.links[li].joint;
        for (int k = 0; k < jnt.nv; ++k) {
            int dof = jnt.vIndex + k;
            const SpatialVec &S = cache.subspace[dof];
            Vec3 col = S.lin + S.ang.cross(worldPoint);
            out[0 * n + dof] = col.x;
            out[1 * n + dof] = col.y;
            out[2 * n + dof] = col.z;
        }
        li = a.links[li].parent;
    }
}

Scalar World::kineticEnergy() const {
    Scalar e = 0;
    for (const Articulation &art : articulations_)
        for (const Link &l : art.links) e += Scalar(0.5) * l.velocity.dot(l.spatialInertia * l.velocity);
    return e;
}

Scalar World::potentialEnergy() const {
    Scalar e = 0;
    for (const Articulation &art : articulations_)
        for (const Link &l : art.links) e -= l.mass * options.gravity.dot(l.worldCom);
    return e;
}

Scalar World::totalMass() const {
    Scalar m = 0;
    for (const Articulation &art : articulations_)
        for (const Link &l : art.links) m += l.mass;
    return m;
}

Vec3 World::centerOfMass() const {
    Vec3 c = Vec3::zero();
    Scalar m = 0;
    for (const Articulation &art : articulations_)
        for (const Link &l : art.links) {
            c += l.worldCom * l.mass;
            m += l.mass;
        }
    return m > kEps ? c / m : Vec3::zero();
}

Vec3 World::linearMomentum() const {
    Vec3 p = Vec3::zero();
    for (const Articulation &art : articulations_)
        for (const Link &l : art.links) p += l.velocity.pointVelocity(l.worldCom) * l.mass;
    return p;
}

Vec3 World::angularMomentum() const {
    Vec3 L = Vec3::zero();
    for (const Articulation &art : articulations_)
        for (const Link &l : art.links) {
            SpatialVec f = l.spatialInertia * l.velocity;
            L += f.ang;
        }
    return L;
}

}  // namespace kn
