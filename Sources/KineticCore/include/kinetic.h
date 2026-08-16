// kinetic.h — stable C ABI for the Kinetic physics core.
//
// The C++ engine lives behind this header so that Swift (and any other language
// with a C FFI) binds to a single, versioned surface. Everything is plain data:
// no C++ types, no exceptions, no ownership subtleties beyond create/destroy.
//
// Angles are radians, lengths metres, masses kilograms, time seconds.

#ifndef KINETIC_H
#define KINETIC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KN_VERSION_MAJOR 1
#define KN_VERSION_MINOR 0
#define KN_VERSION_PATCH 0

typedef struct kn_world kn_world;

// ── enums (values match the C++ side) ───────────────────────────────────

typedef enum {
    KN_GEOM_SPHERE = 0,
    KN_GEOM_BOX = 1,
    KN_GEOM_CAPSULE = 2,
    KN_GEOM_CYLINDER = 3,
    KN_GEOM_PLANE = 4,
    KN_GEOM_CONVEX_HULL = 5,
    KN_GEOM_HEIGHTFIELD = 6
} kn_geom_type;

typedef enum {
    KN_JOINT_FIXED = 0,
    KN_JOINT_REVOLUTE = 1,
    KN_JOINT_PRISMATIC = 2,
    KN_JOINT_SPHERICAL = 3,
    KN_JOINT_FREE = 4
} kn_joint_type;

typedef enum {
    KN_ACTUATOR_MOTOR = 0,
    KN_ACTUATOR_POSITION = 1,
    KN_ACTUATOR_VELOCITY = 2,
    KN_ACTUATOR_DAMPER = 3
} kn_actuator_type;

typedef enum {
    KN_SENSOR_JOINT_POSITION = 0,
    KN_SENSOR_JOINT_VELOCITY = 1,
    KN_SENSOR_ACTUATOR_FORCE = 2,
    KN_SENSOR_ACCELEROMETER = 3,
    KN_SENSOR_GYROSCOPE = 4,
    KN_SENSOR_FRAME_POSITION = 5,
    KN_SENSOR_FRAME_ORIENTATION = 6,
    KN_SENSOR_FRAME_LINEAR_VELOCITY = 7,
    KN_SENSOR_FORCE_TORQUE = 8,
    KN_SENSOR_CONTACT_NORMAL_FORCE = 9,
    KN_SENSOR_RANGEFINDER = 10
} kn_sensor_type;

typedef enum { KN_EQ_WELD = 0, KN_EQ_CONNECT = 1, KN_EQ_JOINT_LOCK = 2 } kn_equality_type;

// ── plain-data descriptors ──────────────────────────────────────────────

typedef struct {
    double timestep;
    double gravity[3];
    int integrator;
    int solverIterations;
    int relaxationIterations;
    double solverTolerance;
    bool warmStart;
    double contactMargin;
    double penetrationSlop;
    double maxCorrectionVelocity;
    double linearDamping;
    double angularDamping;
    double maxVelocity;
    bool enableContacts;
    bool enableJointLimits;
    bool enableEqualities;
    bool multithreaded;
} kn_options;

typedef struct {
    int type;
    double axis[3];
    double originPos[3];
    double originQuat[4];  // (w, x, y, z)
    bool limited;
    double lower, upper;
    double effortLimit, velocityLimit;
    double damping, friction, armature, stiffness, springRef;
} kn_joint_desc;

typedef struct {
    int type;
    double size[3];
    double localPos[3];
    double localQuat[4];
    int meshIndex;

    double friction;
    double torsionalFriction;
    double restitution;
    double stiffnessTimeConst;
    double dampingRatio;
    double margin;

    double rgba[4];
    double metallic;
    double roughness;
    double emissive;

    bool collidable;
    bool visible;
    uint32_t group;
    uint32_t mask;
} kn_geom_desc;

typedef struct {
    int type;
    int articulation;
    int link;
    double gear;
    double kp, kd;
    double ctrlMin, ctrlMax;
    double forceMin, forceMax;
} kn_actuator_desc;

typedef struct {
    int type;
    int articulation;
    int link;
    int dof;
    double localPos[3];
    double localQuat[4];
    double noiseStdDev;
    double bias;
    double cutoff;
} kn_sensor_desc;

typedef struct {
    int type;
    int articulationA, linkA;
    int articulationB, linkB;  // articulationB < 0 anchors to the world
    double anchorA[3], anchorB[3];
    double relQuat[4];
    double target;
    int dof;
    bool active;
    double stiffnessTimeConst;
    double dampingRatio;
} kn_equality_desc;

typedef struct {
    double point[3];
    double normal[3];
    double force[3];
    double depth;
    int geomA, geomB;
} kn_contact;

typedef struct {
    double kinematics, inertia, bias, collision, constraintSetup, solve, integrate, sensors, total;
    int contactCount, constraintCount, broadphasePairs, solverIterations;
    double solverResidual;
} kn_profile;

typedef struct {
    bool hit;
    double distance;
    double point[3];
    double normal[3];
    int geom;
    int articulation;
    int link;
} kn_ray_hit;

// ── lifecycle ───────────────────────────────────────────────────────────

kn_world *kn_world_create(void);
void kn_world_destroy(kn_world *w);
void kn_world_get_options(const kn_world *w, kn_options *out);
void kn_world_set_options(kn_world *w, const kn_options *opts);
void kn_options_defaults(kn_options *out);
void kn_joint_defaults(kn_joint_desc *out);
void kn_geom_defaults(kn_geom_desc *out);
void kn_actuator_defaults(kn_actuator_desc *out);
void kn_sensor_defaults(kn_sensor_desc *out);
void kn_equality_defaults(kn_equality_desc *out);

// ── model construction ──────────────────────────────────────────────────

int kn_add_articulation(kn_world *w, const char *name);
int kn_add_link(kn_world *w, int articulation, int parent, const char *name);
void kn_set_inertial(kn_world *w, int articulation, int link, double mass, const double com[3],
                     const double inertia[9]);
// Convenience: derive the inertia tensor of a primitive at the given density.
void kn_set_inertial_from_geom(kn_world *w, int articulation, int link, int geomType,
                               const double size[3], double density);
void kn_set_joint(kn_world *w, int articulation, int link, const kn_joint_desc *joint);
int kn_add_geom(kn_world *w, int articulation, int link, const kn_geom_desc *geom);
int kn_add_mesh(kn_world *w, const double *vertices, int vertexCount, const uint32_t *indices,
                int indexCount, const char *name);
int kn_add_actuator(kn_world *w, const kn_actuator_desc *actuator, const char *name);
int kn_add_sensor(kn_world *w, const kn_sensor_desc *sensor, const char *name);
int kn_add_equality(kn_world *w, const kn_equality_desc *eq);
void kn_set_self_collision(kn_world *w, int articulation, bool enabled);
void kn_set_articulation_enabled(kn_world *w, int articulation, bool enabled);
void kn_compile(kn_world *w);
bool kn_is_compiled(const kn_world *w);

// ── sizes ───────────────────────────────────────────────────────────────

int kn_nq(const kn_world *w);
int kn_nv(const kn_world *w);
int kn_nu(const kn_world *w);
int kn_nsensordata(const kn_world *w);
int kn_narticulation(const kn_world *w);
int kn_nlink(const kn_world *w);
int kn_ngeom(const kn_world *w);
int kn_nmesh(const kn_world *w);
int kn_link_count(const kn_world *w, int articulation);
int kn_articulation_nq(const kn_world *w, int articulation);
int kn_articulation_nv(const kn_world *w, int articulation);
int kn_articulation_qoffset(const kn_world *w, int articulation);
int kn_articulation_voffset(const kn_world *w, int articulation);

// ── state (direct pointers into the engine's storage) ───────────────────

double *kn_qpos(kn_world *w);
double *kn_qvel(kn_world *w);
double *kn_qacc(kn_world *w);
double *kn_ctrl(kn_world *w);
double *kn_actuator_force(kn_world *w);
double *kn_sensor_data(kn_world *w);
double *kn_qfrc_applied(kn_world *w);
double kn_time(const kn_world *w);
void kn_set_time(kn_world *w, double t);

void kn_reset(kn_world *w);
void kn_step(kn_world *w, int count);
void kn_forward(kn_world *w);
void kn_set_default_pose(kn_world *w, int articulation, const double *q, int count);

void kn_apply_force(kn_world *w, int articulation, int link, const double force[3],
                    const double worldPoint[3]);
void kn_apply_torque(kn_world *w, int articulation, int link, const double torque[3]);
void kn_clear_applied_forces(kn_world *w);

int kn_save_state(const kn_world *w, double *out, int capacity);
void kn_load_state(kn_world *w, const double *in, int count);
int kn_state_size(const kn_world *w);

// ── introspection ───────────────────────────────────────────────────────

// Writes 7 doubles per link: position (3) then quaternion (w, x, y, z).
void kn_link_poses(const kn_world *w, double *out);
// Writes 7 doubles per geom in the same layout.
void kn_geom_poses(const kn_world *w, double *out);
void kn_geom_info(const kn_world *w, int geom, kn_geom_desc *out);
int kn_geom_articulation(const kn_world *w, int geom);
int kn_geom_link(const kn_world *w, int geom);
int kn_mesh_vertex_count(const kn_world *w, int mesh);
int kn_mesh_index_count(const kn_world *w, int mesh);
void kn_mesh_data(const kn_world *w, int mesh, double *vertices, uint32_t *indices);

int kn_contact_count(const kn_world *w);
int kn_get_contacts(const kn_world *w, kn_contact *out, int capacity);
void kn_get_profile(const kn_world *w, kn_profile *out);

void kn_link_name(const kn_world *w, int articulation, int link, char *out, int capacity);
void kn_articulation_name(const kn_world *w, int articulation, char *out, int capacity);
int kn_find_articulation(const kn_world *w, const char *name);
int kn_find_link(const kn_world *w, int articulation, const char *name);
int kn_find_actuator(const kn_world *w, const char *name);
int kn_link_joint_type(const kn_world *w, int articulation, int link);
int kn_link_joint_qindex(const kn_world *w, int articulation, int link);
int kn_link_joint_vindex(const kn_world *w, int articulation, int link);
void kn_link_joint_limits(const kn_world *w, int articulation, int link, double *lower,
                          double *upper, bool *limited);
double kn_link_mass(const kn_world *w, int articulation, int link);
int kn_link_parent(const kn_world *w, int articulation, int link);
void kn_actuator_info(const kn_world *w, int actuator, kn_actuator_desc *out);

double kn_kinetic_energy(const kn_world *w);
double kn_potential_energy(const kn_world *w);
double kn_total_mass(const kn_world *w);
void kn_center_of_mass(const kn_world *w, double out[3]);
void kn_linear_momentum(const kn_world *w, double out[3]);
void kn_angular_momentum(const kn_world *w, double out[3]);

kn_ray_hit kn_raycast(const kn_world *w, const double origin[3], const double dir[3],
                      double maxDistance, uint32_t mask, int ignoreArticulation);

// 3 x nv Jacobian of a world point attached to a link, row-major.
void kn_point_jacobian(const kn_world *w, int articulation, int link, const double worldPoint[3],
                       double *out);
// nv x nv joint-space inertia of one articulation, row-major.
void kn_mass_matrix(const kn_world *w, int articulation, double *out);

const char *kn_version_string(void);

#ifdef __cplusplus
}
#endif

#endif  // KINETIC_H
