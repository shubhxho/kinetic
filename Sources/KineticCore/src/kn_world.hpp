// kn_world.hpp — the simulation world: model storage, state, and the step
// pipeline.
//
// Pipeline per step():
//   1. forwardKinematics()      link poses, spatial velocities, world inertias
//   2. compositeRigidBodyInertia()  joint-space inertia M (CRBA)
//   3. inverseDynamicsBias()    Coriolis + centrifugal + gravity (RNEA)
//   4. applyActuators()         actuator, spring, damping and external forces
//   5. unconstrainedAcceleration()  a_free = M^-1 (tau - c)
//   6. collide()                broadphase + narrowphase + persistent manifolds
//   7. buildConstraints()       contacts, joint limits, equality constraints
//   8. solveConstraints()       projected Gauss-Seidel with warm starting
//   9. integrate()              semi-implicit Euler on the manifold
//  10. computeSensors()
#pragma once

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "kn_collision.hpp"
#include "kn_math.hpp"
#include "kn_model.hpp"
#include "kn_spatial.hpp"

namespace kn {

// Per-articulation scratch space. Sized once at compile() time.
struct ArticulationCache {
    MatX massMatrix;        // nv x nv, holds the LDL^T factors after factorise()
    MatX massMatrixRaw;     // unfactored copy, exposed through the API
    VecX bias;              // C(q, qdot) + gravity, size nv
    VecX accelFree;         // unconstrained acceleration, size nv
    VecX force;             // generalised force applied this step, size nv
    std::vector<SpatialVec> subspace;  // motion subspace per dof, world frame
    std::vector<int> dofLink;          // owning link per dof
    std::vector<SpatialInertia> composite;
    std::vector<SpatialVec> accel;     // scratch for RNEA
    std::vector<SpatialVec> netForce;  // scratch for RNEA
    bool factorOK = true;
};

enum class ConstraintKind : int { Contact = 0, JointLimit = 1, Equality = 2, JointFriction = 3 };

// One constraint block. Touches at most two articulations; the Jacobian rows
// are stored densely over each articulation's own dof block, which stays small.
struct ConstraintBlock {
    ConstraintKind kind = ConstraintKind::Contact;
    int dim = 1;
    int art[2] = {-1, -1};
    std::vector<Scalar> J[2];  // dim x nv_art, row-major
    std::vector<Scalar> B[2];  // M^-1 J^T, stored dim x nv_art (row-major)
    Scalar A[36] = {0};        // dim x dim Delassus block (already regularised)
    Scalar Ainv[36] = {0};
    Scalar bias[6] = {0};
    Scalar lambda[6] = {0};
    Scalar lower[6] = {0};
    Scalar upper[6] = {0};
    Scalar friction = 0;            // Coulomb coefficient for contact blocks
    Scalar torsionalFriction = 0;   // spin-friction coefficient, metres
    int manifold = -1;     // index into World::manifolds_
    int point = -1;        // point index within the manifold
    int sourceIndex = -1;  // joint-limit dof or equality index
};

struct ContactForceRecord {
    int geomA = -1, geomB = -1;
    Vec3 point = Vec3::zero();
    Vec3 normal = Vec3::zero();
    Vec3 force = Vec3::zero();  // world-space force applied to geom A
    Scalar depth = 0;
};

struct StepProfile {
    double kinematics = 0, inertia = 0, bias = 0, collision = 0, constraintSetup = 0,
           solve = 0, integrate = 0, sensors = 0, total = 0;
    int contactCount = 0, constraintCount = 0, broadphasePairs = 0, solverIterations = 0;
    double solverResidual = 0;
};

class World {
   public:
    World();
    ~World();

    // ── model construction ────────────────────────────────────────────
    int addArticulation(const std::string &name);
    int addLink(int articulation, int parent, const std::string &name);
    void setLinkInertial(int art, int link, Scalar mass, const Vec3 &com, const Mat3 &inertia);
    void setJoint(int art, int link, const Joint &joint);
    int addGeom(int art, int link, const Geom &geom);
    int addMesh(const Mesh &mesh);
    int addActuator(const Actuator &actuator);
    int addSensor(const Sensor &sensor);
    int addEquality(const Equality &eq);

    // Freezes the model: assigns state offsets, builds child lists, allocates
    // caches. Must be called before step().
    void compile();
    bool isCompiled() const { return compiled_; }

    // ── state ─────────────────────────────────────────────────────────
    int nq() const { return nq_; }
    int nv() const { return nv_; }
    int nu() const { return int(actuators_.size()); }
    int nsensordata() const { return nsensor_; }

    VecX qpos, qvel, qacc, ctrl, actuatorForce, sensorData, qfrcApplied;
    std::vector<SpatialVec> xfrcApplied;  // per-link external wrench, world frame

    SimOptions options;
    Scalar time = 0;

    void resetState();
    void setDefaultPose(int art, const VecX &q);

    // ── simulation ────────────────────────────────────────────────────
    void step();
    void stepMany(int count);
    void forwardKinematics();
    void forward();  // kinematics + derived quantities without integrating
    void computeSensors();

    // ── queries ───────────────────────────────────────────────────────
    RayHit raycast(const Vec3 &origin, const Vec3 &dir, Scalar maxDist, uint32_t mask = 0xFFFFFFFFu,
                   int ignoreArticulation = -1) const;

    const std::vector<Manifold> &manifolds() const { return manifolds_; }
    const std::vector<ContactForceRecord> &contactForces() const { return contactForces_; }
    const StepProfile &profile() const { return profile_; }

    Scalar kineticEnergy() const;
    Scalar potentialEnergy() const;
    Vec3 centerOfMass() const;
    Vec3 linearMomentum() const;
    Vec3 angularMomentum() const;
    Scalar totalMass() const;

    // 3 x nv Jacobian of a world-space point attached to a link.
    void pointJacobian(int art, int link, const Vec3 &worldPoint, Scalar *out3xnv) const;

    // ── accessors ─────────────────────────────────────────────────────
    const std::vector<Articulation> &articulations() const { return articulations_; }
    std::vector<Articulation> &articulationsMutable() { return articulations_; }
    const std::vector<Geom> &geoms() const { return geoms_; }
    std::vector<Geom> &geomsMutable() { return geoms_; }
    const std::vector<Mesh> &meshes() const { return meshes_; }
    const std::vector<Actuator> &actuators() const { return actuators_; }
    std::vector<Actuator> &actuatorsMutable() { return actuators_; }
    const std::vector<Sensor> &sensors() const { return sensors_; }
    std::vector<Equality> &equalitiesMutable() { return equalities_; }
    const std::vector<Equality> &equalities() const { return equalities_; }
    const ArticulationCache &cache(int art) const { return caches_[art]; }

    int findArticulation(const std::string &name) const;
    int findLink(int art, const std::string &name) const;
    int findGeom(const std::string &name) const;
    int findActuator(const std::string &name) const;

    const Link &link(int art, int l) const { return articulations_[art].links[l]; }

    // Flat index of a link across all articulations; indexes xfrcApplied and the
    // render/telemetry link tables.
    int linkGlobalIndex(int art, int l) const { return linkOffset_[art] + l; }
    int linkCount() const { return linkCount_; }
    void applyForceAtPoint(int art, int link, const Vec3 &force, const Vec3 &worldPoint);
    void applyTorque(int art, int link, const Vec3 &torque);
    void clearAppliedForces();

    // Snapshot / restore of the full integrable state (for replay and for the
    // finite-difference derivative helpers).
    void saveState(VecX &out) const;
    void loadState(const VecX &in);

   private:
    void computeSubspace();
    void compositeRigidBodyInertia();
    void inverseDynamicsBias();
    void applyForces();
    void factorMass();
    void unconstrainedAcceleration();
    void collide();
    void buildConstraints();
    void solveConstraints();
    void integrate(Scalar h);
    void integratePositions(Scalar h, const VecX &vel);
    void evaluateSmoothAcceleration(VecX &accelOut);
    void integrateRK4(Scalar h);
    void solveMassInverse(int art, const Scalar *rhs, Scalar *out) const;

    std::vector<Articulation> articulations_;
    std::vector<Geom> geoms_;
    std::vector<Mesh> meshes_;
    std::vector<Actuator> actuators_;
    std::vector<Sensor> sensors_;
    std::vector<Equality> equalities_;
    std::vector<ArticulationCache> caches_;
    std::vector<VecX> defaultPose_;

    std::vector<int> linkOffset_;
    int nq_ = 0, nv_ = 0, nsensor_ = 0, linkCount_ = 0;
    bool compiled_ = false;

    // collision state
    struct NarrowphaseResult {
        int count = 0;
        bool persistent = false;
        Scalar margin = 0;
        ContactPoint points[4];
    };
    std::vector<std::pair<int, int>> candidatePairs_;
    std::vector<NarrowphaseResult> narrowphaseResults_;
    Broadphase broadphase_;
    std::vector<AABB> aabbs_;
    std::vector<Transform> geomPose_;
    std::unordered_map<uint64_t, Manifold> manifoldCache_;
    std::vector<Manifold> manifolds_;
    std::vector<ContactForceRecord> contactForces_;

    // solver state
    std::vector<ConstraintBlock> blocks_;
    VecX velPredicted_;  // v + h * a_free
    VecX deltaVel_;      // accumulated M^-1 J^T lambda
    VecX scratchNv_;

    StepProfile profile_;
};

}  // namespace kn
