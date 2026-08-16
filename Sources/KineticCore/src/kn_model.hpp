// kn_model.hpp — scene description: geometry, links, joints, articulations,
// actuators, sensors and equality constraints.
#pragma once

#include <string>
#include <vector>

#include "kn_math.hpp"
#include "kn_spatial.hpp"

namespace kn {

// ─────────────────────────────────────────────────────────── geometry ──

enum class GeomType : int {
    Sphere = 0,
    Box = 1,
    Capsule = 2,   // +Z aligned, size = (radius, halfLength, _)
    Cylinder = 3,  // +Z aligned, size = (radius, halfLength, _)
    Plane = 4,     // +Z normal, infinite; size.x/size.y are render extents only
    ConvexHull = 5,
    Heightfield = 6,
};

struct Material {
    Scalar friction = 1.0;         // Coulomb friction coefficient
    Scalar torsionalFriction = 0.005;
    Scalar rollingFriction = 0.0;
    Scalar restitution = 0.0;      // 0 = fully inelastic
    Scalar stiffnessTimeConst = 0.02;  // contact soft-constraint time constant [s]
    Scalar dampingRatio = 1.0;         // contact soft-constraint damping ratio
    Scalar margin = 0.0;               // collision margin [m]
};

struct RenderMaterial {
    Scalar rgba[4] = {0.82, 0.83, 0.85, 1.0};
    Scalar metallic = 0.0;
    Scalar roughness = 0.55;
    Scalar emissive = 0.0;
};

// A convex hull or render mesh. `faces` is a triangle index list; the collision
// path only uses `vertices` (support mapping), the renderer uses both.
struct Mesh {
    std::string name;
    std::vector<Vec3> vertices;
    std::vector<Vec3> normals;
    std::vector<uint32_t> faces;
    Vec3 aabbMin = Vec3::zero(), aabbMax = Vec3::zero();
    Scalar boundingRadius = 0;

    void computeBounds();
};

struct Geom {
    std::string name;
    GeomType type = GeomType::Sphere;
    Vec3 size = {0.1, 0.1, 0.1};
    Transform localPose;  // relative to the owning link frame
    int meshIndex = -1;

    Material material;
    RenderMaterial render;

    bool collidable = true;
    bool visible = true;
    uint32_t group = 1;          // this geom's membership bits
    uint32_t mask = 0xFFFFFFFFu; // which groups it may collide with

    // Filled in during World::compile().
    int articulation = -1;
    int link = -1;
    int index = -1;

    Scalar boundingRadius() const;
};

// ────────────────────────────────────────────────────────────── joints ──

enum class JointType : int {
    Fixed = 0,
    Revolute = 1,   // 1 dof about `axis`
    Prismatic = 2,  // 1 dof along `axis`
    Spherical = 3,  // 3 dof, q = unit quaternion
    Free = 4,       // 6 dof, q = (position, quaternion), v = (linear, angular)
};

inline int jointDofCount(JointType t) {
    switch (t) {
        case JointType::Fixed: return 0;
        case JointType::Revolute:
        case JointType::Prismatic: return 1;
        case JointType::Spherical: return 3;
        case JointType::Free: return 6;
    }
    return 0;
}

inline int jointCoordCount(JointType t) {
    switch (t) {
        case JointType::Fixed: return 0;
        case JointType::Revolute:
        case JointType::Prismatic: return 1;
        case JointType::Spherical: return 4;
        case JointType::Free: return 7;
    }
    return 0;
}

struct Joint {
    JointType type = JointType::Fixed;
    Vec3 axis = Vec3::unitZ();   // in the joint frame (== link frame at q = 0)
    Transform origin;            // parent link frame -> joint frame

    bool limited = false;
    Scalar lower = 0, upper = 0;      // [rad] or [m]
    Scalar effortLimit = 0;           // 0 = unlimited
    Scalar velocityLimit = 0;         // 0 = unlimited

    Scalar damping = 0;      // viscous, integrated implicitly
    Scalar friction = 0;     // dry Coulomb friction torque, solved as a constraint
    Scalar armature = 0;     // rotor inertia added to the diagonal of M
    Scalar stiffness = 0;    // linear spring toward springRef
    Scalar springRef = 0;

    // Filled in during World::compile().
    int qIndex = 0;   // offset into the articulation's qpos block
    int vIndex = 0;   // offset into the articulation's qvel block
    int nq = 0, nv = 0;
};

struct Link {
    std::string name;
    int parent = -1;  // index within the articulation; -1 for the root

    Joint joint;

    Scalar mass = 0;
    Vec3 com = Vec3::zero();      // centre of mass in the link frame
    Mat3 inertia = Mat3::zero();  // about the com, in link frame axes

    std::vector<int> geoms;     // indices into World::geoms
    std::vector<int> children;  // filled during compile()

    // Cached kinematics (world frame), refreshed by forwardKinematics().
    Transform pose;             // link frame -> world
    Vec3 jointAnchor;           // world position of the joint origin
    Vec3 worldCom;              // world position of the centre of mass
    SpatialVec velocity;        // spatial velocity of the link, world frame
    SpatialInertia spatialInertia;
};

// A kinematic tree. Free-floating bodies are articulations with a single link
// and a Free root joint, so the solver only ever sees one kind of object.
struct Articulation {
    std::string name;
    std::vector<Link> links;
    int qOffset = 0, vOffset = 0;  // offsets into the world state vectors
    int nq = 0, nv = 0;
    bool selfCollision = false;
    bool enabled = true;
};

// ─────────────────────────────────────────────────────────── actuators ──

enum class ActuatorType : int {
    Motor = 0,     // force = gear * ctrl
    Position = 1,  // PD toward ctrl
    Velocity = 2,  // D toward ctrl
    Damper = 3,    // force = -gear * ctrl * qvel
};

struct Actuator {
    std::string name;
    ActuatorType type = ActuatorType::Motor;
    int articulation = 0;
    int link = 0;
    int dof = 0;  // global index into qvel

    Scalar gear = 1.0;
    Scalar kp = 0, kd = 0;
    Scalar ctrlMin = -1e30, ctrlMax = 1e30;
    Scalar forceMin = -1e30, forceMax = 1e30;
};

// ───────────────────────────────────────────────────────────── sensors ──

enum class SensorType : int {
    JointPosition = 0,
    JointVelocity = 1,
    ActuatorForce = 2,
    IMUAccelerometer = 3,
    IMUGyroscope = 4,
    FramePosition = 5,
    FrameOrientation = 6,
    FrameLinearVelocity = 7,
    ForceTorque = 8,
    ContactNormalForce = 9,
    Rangefinder = 10,
};

struct Sensor {
    std::string name;
    SensorType type = SensorType::JointPosition;
    int articulation = 0;
    int link = 0;
    int dof = -1;
    Transform localPose;  // for frame/IMU/rangefinder sensors
    Scalar noiseStdDev = 0;
    Scalar bias = 0;
    Scalar cutoff = 0;  // 0 = no clamping
    int dim = 1;
    int offset = 0;  // offset into World::sensorData
};

// ──────────────────────────────────────────────────── equality joints ──

enum class EqualityType : int {
    Weld = 0,     // lock two links rigidly
    Connect = 1,  // ball joint between two links (3 dof)
    JointLock = 2 // hold a scalar dof at a target
};

struct Equality {
    EqualityType type = EqualityType::Connect;
    int articulationA = 0, linkA = 0;
    int articulationB = -1, linkB = -1;  // -1 = world
    Vec3 anchorA = Vec3::zero(), anchorB = Vec3::zero();
    Quat relPose = Quat::identity();
    Scalar target = 0;
    int dof = -1;
    bool active = true;
    Scalar stiffnessTimeConst = 0.02;
    Scalar dampingRatio = 1.0;
};

// ─────────────────────────────────────────────────────── sim options ──

enum class Integrator : int { SemiImplicitEuler = 0, RK4 = 1, ImplicitFast = 2 };

struct SimOptions {
    Scalar timestep = 1.0 / 500.0;
    Vec3 gravity = {0, 0, -9.81};
    Integrator integrator = Integrator::SemiImplicitEuler;

    int solverIterations = 30;      // primary PGS sweeps
    int relaxationIterations = 6;   // low-stiffness polish sweeps
    Scalar solverTolerance = 1e-10;
    bool warmStart = true;

    Scalar contactMargin = 0.002;      // generate contacts this far apart [m]
    Scalar penetrationSlop = 0.0005;   // allowed penetration before correction [m]
    Scalar maxCorrectionVelocity = 3.0;
    int frictionCorners = 0;           // 0 = true cone projection, >0 = pyramid

    Scalar linearDamping = 0.0;
    Scalar angularDamping = 0.0;
    Scalar maxVelocity = 1000.0;

    bool enableContacts = true;
    bool enableJointLimits = true;
    bool enableEqualities = true;
    bool multithreaded = true;
};

}  // namespace kn
