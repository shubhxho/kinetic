// kn_solver.cpp — constraint assembly and the projected Gauss-Seidel solver.
//
// Constraints are solved at the velocity level against the Delassus operator
// A = J M^-1 J^T. Position error is handled with a soft (Baumgarte-with-CFM)
// formulation parameterised by a time constant and a damping ratio, so contact
// stiffness is expressed in physical units and is independent of mass scale:
//
//   omega = 1 / max(timeConst, 2h),  zeta = dampingRatio
//   cfm   = A_nn / (h * (2*zeta*omega + h*omega^2))
//   erp   = h*omega^2 / (2*zeta*omega + h*omega^2)
//   bias  = (erp / h) * penetration
//
// Friction uses a true second-order cone projection rather than a linearised
// pyramid, so friction is isotropic (no direction-dependent grip).

#include <algorithm>
#include <cmath>

#include "kn_world.hpp"

namespace kn {

namespace {

struct Softness {
    Scalar cfm;
    Scalar erp;
};

Softness computeSoftness(Scalar Ann, Scalar h, Scalar timeConst, Scalar dampingRatio) {
    Scalar omega = Scalar(1) / std::max(timeConst, 2 * h);
    Scalar zeta = std::max(dampingRatio, Scalar(1e-3));
    Scalar denom = 2 * zeta * omega + h * omega * omega;
    Softness s;
    s.cfm = Ann / (h * denom);
    s.erp = h * omega * omega / denom;
    return s;
}

}  // namespace

void World::buildConstraints() {
    blocks_.clear();
    const Scalar h = options.timestep;

    // Predicted velocity if no constraint acted this step.
    velPredicted_.assign(nv_, 0);
    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        const Articulation &art = articulations_[ai];
        const ArticulationCache &cache = caches_[ai];
        for (int k = 0; k < art.nv; ++k)
            velPredicted_[art.vOffset + k] = qvel[art.vOffset + k] + h * cache.accelFree[k];
    }
    deltaVel_.assign(nv_, 0);

    std::vector<Scalar> jac;  // scratch, 3 x nv

    auto allocBlock = [&](ConstraintBlock &blk, int artA, int artB, int dim) {
        blk.dim = dim;
        blk.art[0] = artA;
        blk.art[1] = (artB == artA) ? -1 : artB;
        for (int s = 0; s < 2; ++s) {
            int a = blk.art[s];
            int n = (a >= 0) ? articulations_[a].nv : 0;
            blk.J[s].assign(std::size_t(dim) * n, 0);
            blk.B[s].assign(std::size_t(dim) * n, 0);
        }
    };

    // Adds +/- the point Jacobian of (art, link) at `p`, projected onto `dirs`,
    // into slot `s` of the block. `sign` is +1 for body A, -1 for body B.
    auto addPointRows = [&](ConstraintBlock &blk, int slot, int art, int link, const Vec3 &p,
                            const Vec3 *dirs, int dim, Scalar sign) {
        if (art < 0 || articulations_[art].nv == 0) return;
        const int n = articulations_[art].nv;
        jac.assign(std::size_t(3) * n, 0);
        pointJacobian(art, link, p, jac.data());
        for (int d = 0; d < dim; ++d) {
            const Vec3 &dir = dirs[d];
            Scalar *row = blk.J[slot].data() + std::size_t(d) * n;
            for (int k = 0; k < n; ++k)
                row[k] += sign * (dir.x * jac[k] + dir.y * jac[n + k] + dir.z * jac[2 * n + k]);
        }
    };

    auto addAngularRows = [&](ConstraintBlock &blk, int slot, int art, int link, const Vec3 *dirs,
                              int dim, int rowOffset, Scalar sign) {
        if (art < 0 || articulations_[art].nv == 0) return;
        const Articulation &a = articulations_[art];
        const ArticulationCache &cache = caches_[art];
        const int n = a.nv;
        int li = link;
        while (li >= 0) {
            const Joint &jnt = a.links[li].joint;
            for (int k = 0; k < jnt.nv; ++k) {
                int dof = jnt.vIndex + k;
                const Vec3 &ang = cache.subspace[dof].ang;
                for (int d = 0; d < dim; ++d)
                    blk.J[slot][std::size_t(rowOffset + d) * n + dof] += sign * dirs[d].dot(ang);
            }
            li = a.links[li].parent;
        }
    };

    // Fills B = M^-1 J^T and the dense Delassus block.
    auto finalizeBlock = [&](ConstraintBlock &blk) {
        const int dim = blk.dim;
        for (int s = 0; s < 2; ++s) {
            int a = blk.art[s];
            if (a < 0) continue;
            int n = articulations_[a].nv;
            if (n == 0) continue;
            for (int d = 0; d < dim; ++d)
                solveMassInverse(a, blk.J[s].data() + std::size_t(d) * n,
                                 blk.B[s].data() + std::size_t(d) * n);
        }
        for (int d = 0; d < dim; ++d)
            for (int e = 0; e < dim; ++e) {
                Scalar sum = 0;
                for (int s = 0; s < 2; ++s) {
                    int a = blk.art[s];
                    if (a < 0) continue;
                    int n = articulations_[a].nv;
                    const Scalar *jr = blk.J[s].data() + std::size_t(d) * n;
                    const Scalar *br = blk.B[s].data() + std::size_t(e) * n;
                    for (int k = 0; k < n; ++k) sum += jr[k] * br[k];
                }
                blk.A[d * 6 + e] = sum;
            }
    };

    auto rowDot = [&](const ConstraintBlock &blk, int row, const VecX &v) {
        Scalar sum = 0;
        for (int s = 0; s < 2; ++s) {
            int a = blk.art[s];
            if (a < 0) continue;
            int n = articulations_[a].nv;
            int off = articulations_[a].vOffset;
            const Scalar *jr = blk.J[s].data() + std::size_t(row) * n;
            for (int k = 0; k < n; ++k) sum += jr[k] * v[off + k];
        }
        return sum;
    };

    // ── contacts ──────────────────────────────────────────────────────
    if (options.enableContacts) {
        for (int mi = 0; mi < int(manifolds_.size()); ++mi) {
            Manifold &man = manifolds_[mi];
            for (int pi = 0; pi < man.count; ++pi) {
                ContactPoint &cp = man.points[pi];
                Vec3 t1, t2;
                orthoBasis(cp.normal, t1, t2);
                Vec3 dirs[3] = {cp.normal, t1, t2};

                ConstraintBlock blk;
                blk.kind = ConstraintKind::Contact;
                blk.manifold = mi;
                blk.point = pi;
                blk.friction = man.friction;
                allocBlock(blk, man.artA, man.artB, 3);

                addPointRows(blk, 0, man.artA, man.linkA, cp.position, dirs, 3, +1);
                int slotB = (blk.art[1] >= 0) ? 1 : 0;
                addPointRows(blk, slotB, man.artB, man.linkB, cp.position, dirs, 3, -1);
                finalizeBlock(blk);

                if (blk.A[0] < 1e-12) continue;  // both bodies static

                Softness soft = computeSoftness(blk.A[0], h, man.timeConst, man.dampingRatio);
                blk.A[0] += soft.cfm;

                Scalar penetration = std::max(Scalar(0), cp.depth - options.penetrationSlop);
                Scalar biasVel = clampf(soft.erp / h * penetration, 0, options.maxCorrectionVelocity);

                // Restitution uses the pre-step approach velocity.
                Scalar vnPre = rowDot(blk, 0, qvel);
                Scalar restitution = 0;
                if (man.restitution > 0 && vnPre < -0.2)
                    restitution = -man.restitution * vnPre;

                blk.bias[0] = std::max(biasVel, restitution);
                blk.bias[1] = 0;
                blk.bias[2] = 0;
                blk.lower[0] = 0;
                blk.upper[0] = 1e30;

                if (options.warmStart) {
                    blk.lambda[0] = cp.impulseNormal;
                    blk.lambda[1] = cp.impulseT1;
                    blk.lambda[2] = cp.impulseT2;
                } else {
                    blk.lambda[0] = blk.lambda[1] = blk.lambda[2] = 0;
                }
                blocks_.push_back(std::move(blk));
            }
        }
    }

    // ── joint limits and dry friction ─────────────────────────────────
    for (size_t ai = 0; ai < articulations_.size(); ++ai) {
        const Articulation &art = articulations_[ai];
        if (art.nv == 0) continue;
        for (size_t li = 0; li < art.links.size(); ++li) {
            const Joint &jnt = art.links[li].joint;
            if (jnt.nv != 1) continue;
            int dof = jnt.vIndex;
            Scalar q = qpos[art.qOffset + jnt.qIndex];

            if (options.enableJointLimits && jnt.limited) {
                const Scalar activation = 0.03;
                struct LimitSide {
                    Scalar sign;
                    Scalar violation;
                };
                LimitSide sides[2] = {{+1, jnt.lower + activation - q},
                                      {-1, q - (jnt.upper - activation)}};
                for (int s = 0; s < 2; ++s) {
                    if (sides[s].violation < 0) continue;
                    ConstraintBlock blk;
                    blk.kind = ConstraintKind::JointLimit;
                    blk.sourceIndex = art.vOffset + dof;
                    allocBlock(blk, int(ai), -1, 1);
                    blk.J[0][dof] = sides[s].sign;
                    finalizeBlock(blk);
                    if (blk.A[0] < 1e-12) continue;
                    Scalar depth = sides[s].violation - activation;  // >0 only past the limit
                    Softness soft = computeSoftness(blk.A[0], h, 2 * h, 1.0);
                    blk.A[0] += soft.cfm;
                    blk.bias[0] = clampf(soft.erp / h * std::max(Scalar(0), depth), 0,
                                         options.maxCorrectionVelocity);
                    blk.lower[0] = 0;
                    blk.upper[0] = 1e30;
                    blocks_.push_back(std::move(blk));
                }
            }

            if (jnt.friction > 0) {
                ConstraintBlock blk;
                blk.kind = ConstraintKind::JointFriction;
                blk.sourceIndex = art.vOffset + dof;
                allocBlock(blk, int(ai), -1, 1);
                blk.J[0][dof] = 1;
                finalizeBlock(blk);
                if (blk.A[0] < 1e-12) continue;
                blk.bias[0] = 0;
                blk.lower[0] = -jnt.friction * h;
                blk.upper[0] = jnt.friction * h;
                blocks_.push_back(std::move(blk));
            }
        }
    }

    // ── equality constraints ──────────────────────────────────────────
    if (options.enableEqualities) {
        for (size_t ei = 0; ei < equalities_.size(); ++ei) {
            const Equality &eq = equalities_[ei];
            if (!eq.active) continue;

            if (eq.type == EqualityType::JointLock) {
                if (eq.dof < 0) continue;
                int art = eq.articulationA;
                int localDof = eq.dof - articulations_[art].vOffset;
                if (localDof < 0 || localDof >= articulations_[art].nv) continue;
                ConstraintBlock blk;
                blk.kind = ConstraintKind::Equality;
                blk.sourceIndex = int(ei);
                allocBlock(blk, art, -1, 1);
                blk.J[0][localDof] = 1;
                finalizeBlock(blk);
                if (blk.A[0] < 1e-12) continue;
                Scalar q = qpos[articulations_[art].qOffset + localDof];
                Softness soft = computeSoftness(blk.A[0], h, eq.stiffnessTimeConst, eq.dampingRatio);
                blk.A[0] += soft.cfm;
                blk.bias[0] = -soft.erp / h * (q - eq.target);
                blk.lower[0] = -1e30;
                blk.upper[0] = 1e30;
                blocks_.push_back(std::move(blk));
                continue;
            }

            Vec3 worldA = articulations_[eq.articulationA].links[eq.linkA].pose.apply(eq.anchorA);
            Vec3 worldB = eq.articulationB >= 0
                              ? articulations_[eq.articulationB].links[eq.linkB].pose.apply(eq.anchorB)
                              : eq.anchorB;

            int dim = eq.type == EqualityType::Weld ? 6 : 3;
            ConstraintBlock blk;
            blk.kind = ConstraintKind::Equality;
            blk.sourceIndex = int(ei);
            allocBlock(blk, eq.articulationA, eq.articulationB, dim);

            Vec3 axes[3] = {Vec3::unitX(), Vec3::unitY(), Vec3::unitZ()};
            Vec3 anchor = (worldA + worldB) * Scalar(0.5);
            addPointRows(blk, 0, eq.articulationA, eq.linkA, anchor, axes, 3, +1);
            int slotB = (blk.art[1] >= 0) ? 1 : 0;
            if (eq.articulationB >= 0)
                addPointRows(blk, slotB, eq.articulationB, eq.linkB, anchor, axes, 3, -1);

            Vec3 posErr = worldA - worldB;
            Vec3 rotErr = Vec3::zero();
            if (dim == 6) {
                addAngularRows(blk, 0, eq.articulationA, eq.linkA, axes, 3, 3, +1);
                if (eq.articulationB >= 0)
                    addAngularRows(blk, slotB, eq.articulationB, eq.linkB, axes, 3, 3, -1);
                Quat qa = articulations_[eq.articulationA].links[eq.linkA].pose.rot;
                Quat qb = eq.articulationB >= 0
                              ? articulations_[eq.articulationB].links[eq.linkB].pose.rot
                              : Quat::identity();
                Quat err = qa * (qb * eq.relPose).conjugate();
                rotErr = err.toRotationVector();
            }
            finalizeBlock(blk);

            bool degenerate = true;
            for (int d = 0; d < dim; ++d)
                if (blk.A[d * 6 + d] > 1e-12) degenerate = false;
            if (degenerate) continue;

            for (int d = 0; d < dim; ++d) {
                Scalar Add = std::max(blk.A[d * 6 + d], Scalar(1e-12));
                Softness soft = computeSoftness(Add, h, eq.stiffnessTimeConst, eq.dampingRatio);
                blk.A[d * 6 + d] += soft.cfm;
                Scalar err = d < 3 ? posErr[d] : rotErr[d - 3];
                blk.bias[d] = clampf(-soft.erp / h * err, -options.maxCorrectionVelocity * 10,
                                     options.maxCorrectionVelocity * 10);
                blk.lower[d] = -1e30;
                blk.upper[d] = 1e30;
            }
            blocks_.push_back(std::move(blk));
        }
    }

    profile_.constraintCount = int(blocks_.size());
}

void World::solveConstraints() {
    if (blocks_.empty()) {
        for (int k = 0; k < nv_; ++k) qacc[k] = (velPredicted_[k] - qvel[k]) / options.timestep;
        return;
    }

    const Scalar h = options.timestep;

    // Applies `delta` of row `row` to the accumulated velocity change.
    auto applyImpulse = [&](const ConstraintBlock &blk, int row, Scalar delta) {
        if (delta == 0) return;
        for (int s = 0; s < 2; ++s) {
            int a = blk.art[s];
            if (a < 0) continue;
            int n = articulations_[a].nv;
            int off = articulations_[a].vOffset;
            const Scalar *br = blk.B[s].data() + std::size_t(row) * n;
            for (int k = 0; k < n; ++k) deltaVel_[off + k] += br[k] * delta;
        }
    };

    auto rowVelocity = [&](const ConstraintBlock &blk, int row) {
        Scalar sum = 0;
        for (int s = 0; s < 2; ++s) {
            int a = blk.art[s];
            if (a < 0) continue;
            int n = articulations_[a].nv;
            int off = articulations_[a].vOffset;
            const Scalar *jr = blk.J[s].data() + std::size_t(row) * n;
            for (int k = 0; k < n; ++k) sum += jr[k] * (velPredicted_[off + k] + deltaVel_[off + k]);
        }
        return sum;
    };

    // Warm start.
    if (options.warmStart) {
        for (ConstraintBlock &blk : blocks_)
            for (int d = 0; d < blk.dim; ++d) applyImpulse(blk, d, blk.lambda[d]);
    } else {
        for (ConstraintBlock &blk : blocks_)
            for (int d = 0; d < 6; ++d) blk.lambda[d] = 0;
    }

    Scalar residual = 0;
    int iterations = 0;
    const int totalIters = options.solverIterations + options.relaxationIterations;
    for (int iter = 0; iter < totalIters; ++iter) {
        residual = 0;
        iterations = iter + 1;

        for (ConstraintBlock &blk : blocks_) {
            if (blk.kind == ConstraintKind::Contact) {
                // Normal first, so friction sees the updated normal impulse.
                Scalar vn = rowVelocity(blk, 0);
                Scalar deltaN = -(vn - blk.bias[0]) / blk.A[0];
                Scalar newN = std::max(Scalar(0), blk.lambda[0] + deltaN);
                deltaN = newN - blk.lambda[0];
                blk.lambda[0] = newN;
                applyImpulse(blk, 0, deltaN);
                residual = std::max(residual, std::abs(deltaN));

                Scalar limit = blk.friction * blk.lambda[0];
                Scalar lt1 = blk.lambda[1], lt2 = blk.lambda[2];
                Scalar vt1 = rowVelocity(blk, 1);
                Scalar d1 = -vt1 / std::max(blk.A[1 * 6 + 1], Scalar(1e-12));
                Scalar vt2 = rowVelocity(blk, 2);
                Scalar d2 = -vt2 / std::max(blk.A[2 * 6 + 2], Scalar(1e-12));
                Scalar n1 = lt1 + d1, n2 = lt2 + d2;
                // Second-order cone projection: isotropic Coulomb friction.
                Scalar mag = std::sqrt(n1 * n1 + n2 * n2);
                if (mag > limit && mag > 1e-18) {
                    Scalar scale = limit / mag;
                    n1 *= scale;
                    n2 *= scale;
                }
                blk.lambda[1] = n1;
                blk.lambda[2] = n2;
                applyImpulse(blk, 1, n1 - lt1);
                applyImpulse(blk, 2, n2 - lt2);
                residual = std::max(residual, std::max(std::abs(n1 - lt1), std::abs(n2 - lt2)));
            } else {
                for (int d = 0; d < blk.dim; ++d) {
                    Scalar Add = std::max(blk.A[d * 6 + d], Scalar(1e-12));
                    Scalar v = rowVelocity(blk, d);
                    Scalar delta = -(v - blk.bias[d]) / Add;
                    Scalar next = clampf(blk.lambda[d] + delta, blk.lower[d], blk.upper[d]);
                    delta = next - blk.lambda[d];
                    blk.lambda[d] = next;
                    applyImpulse(blk, d, delta);
                    residual = std::max(residual, std::abs(delta));
                }
            }
        }
        if (residual < options.solverTolerance) break;
    }

    profile_.solverIterations = iterations;
    profile_.solverResidual = double(residual);

    // Write impulses back for warm starting and report contact forces.
    contactForces_.clear();
    for (const ConstraintBlock &blk : blocks_) {
        if (blk.kind != ConstraintKind::Contact) continue;
        Manifold &man = manifolds_[blk.manifold];
        ContactPoint &cp = man.points[blk.point];
        cp.impulseNormal = blk.lambda[0];
        cp.impulseT1 = blk.lambda[1];
        cp.impulseT2 = blk.lambda[2];

        Vec3 t1, t2;
        orthoBasis(cp.normal, t1, t2);
        Vec3 force = (cp.normal * blk.lambda[0] + t1 * blk.lambda[1] + t2 * blk.lambda[2]) / h;
        if (blk.lambda[0] > 0 || std::abs(blk.lambda[1]) > 0 || std::abs(blk.lambda[2]) > 0) {
            ContactForceRecord rec;
            rec.geomA = man.geomA;
            rec.geomB = man.geomB;
            rec.point = cp.position;
            rec.normal = cp.normal;
            rec.force = force;
            rec.depth = cp.depth;
            contactForces_.push_back(rec);
        }
    }

    // Final velocities and the reported acceleration.
    for (int k = 0; k < nv_; ++k) {
        Scalar vNew = velPredicted_[k] + deltaVel_[k];
        qacc[k] = (vNew - qvel[k]) / h;
    }
}

}  // namespace kn
