// KineticCore benchmark + invariant suite.
//
// Compiles against kinetic.h and the C++ sources. No Swift, no Metal. This is
// the path that can run on Linux: the same SceneLibrary geometries the CLI
// benches, driven through the public C ABI.
//
// Absolute milliseconds-per-step are hardware-dependent. The --check gate
// asserts sizes, contact character, finite state, stack stability, serial vs
// threaded bit-identity, and a coarse cost ordering. It does not assert the
// published M4 table.

#include "kinetic.h"

#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr int kWarmup = 50;

struct SceneSpec {
    const char *id;
    int nv;
    int geoms;
    kn_world *(*build)();
};

struct BenchRow {
    const char *id;
    int nv = 0;
    int geoms = 0;
    int steps = 0;
    double seconds = 0;
    double elapsed = 0;
    double ms_per_step = 0;
    double steps_per_s = 0;
    double realtime = 0;
    int contacts = 0;
    bool finite = false;
    kn_profile profile{};
};

struct Check {
    std::string name;
    std::string detail;
    bool passed = false;
};

std::vector<Check> g_checks;
int g_failures = 0;
bool g_json = false;

void check(const char *name, const std::string &detail, bool passed) {
    g_checks.push_back({name, detail, passed});
    if (!g_json) {
        std::printf("  %s  %-36s%s\n", passed ? "PASS" : "FAIL", name, detail.c_str());
    }
    if (!passed) ++g_failures;
}

void ident(double q[4]) {
    q[0] = 1;
    q[1] = q[2] = q[3] = 0;
}

void axis_angle(double ax, double ay, double az, double angle, double q[4]) {
    double n = std::sqrt(ax * ax + ay * ay + az * az);
    if (n < 1e-12) {
        ident(q);
        return;
    }
    ax /= n;
    ay /= n;
    az /= n;
    const double s = std::sin(angle * 0.5);
    q[0] = std::cos(angle * 0.5);
    q[1] = ax * s;
    q[2] = ay * s;
    q[3] = az * s;
}

void set_joint(kn_world *w, int art, int link, int type, double ax, double ay, double az, double ox,
               double oy, double oz, bool limited, double lower, double upper, double damping,
               double armature, double effort = 0) {
    kn_joint_desc d;
    kn_joint_defaults(&d);
    d.type = type;
    d.axis[0] = ax;
    d.axis[1] = ay;
    d.axis[2] = az;
    d.originPos[0] = ox;
    d.originPos[1] = oy;
    d.originPos[2] = oz;
    ident(d.originQuat);
    d.limited = limited;
    d.lower = lower;
    d.upper = upper;
    d.damping = damping;
    d.armature = armature;
    d.effortLimit = effort;
    kn_set_joint(w, art, link, &d);
}

int add_geom(kn_world *w, int art, int link, int type, double sx, double sy, double sz, double px,
             double py, double pz, const double *quat, double friction, double restitution,
             bool collidable, double torsional = 0) {
    kn_geom_desc d;
    kn_geom_defaults(&d);
    d.type = type;
    d.size[0] = sx;
    d.size[1] = sy;
    d.size[2] = sz;
    d.localPos[0] = px;
    d.localPos[1] = py;
    d.localPos[2] = pz;
    if (quat) {
        for (int i = 0; i < 4; ++i) d.localQuat[i] = quat[i];
    } else {
        ident(d.localQuat);
    }
    d.friction = friction;
    d.restitution = restitution;
    d.torsionalFriction = torsional;
    d.collidable = collidable;
    d.group = 1;
    return kn_add_geom(w, art, link, &d);
}

int add_ground(kn_world *w, double height = 0, double friction = 1.0, double extent = 60) {
    const int art = kn_add_articulation(w, "world");
    const int link = kn_add_link(w, art, -1, "ground");
    set_joint(w, art, link, KN_JOINT_FIXED, 0, 0, 1, 0, 0, 0, false, 0, 0, 0, 0);
    add_geom(w, art, link, KN_GEOM_PLANE, extent, extent, 0, 0, 0, height, nullptr, friction, 0,
             true);
    return art;
}

int add_free_body(kn_world *w, const char *name, int type, double sx, double sy, double sz,
                  double density, double px, double py, double pz, const double *quat,
                  double friction, double restitution) {
    const int art = kn_add_articulation(w, name);
    const int link = kn_add_link(w, art, -1, name);
    set_joint(w, art, link, KN_JOINT_FREE, 0, 0, 1, 0, 0, 0, false, 0, 0, 0, 0);
    const double size[3] = {sx, sy, sz};
    kn_set_inertial_from_geom(w, art, link, type, size, density);
    add_geom(w, art, link, type, sx, sy, sz, 0, 0, 0, nullptr, friction, restitution, true);
    double q[7] = {px, py, pz, 1, 0, 0, 0};
    if (quat) {
        q[3] = quat[0];
        q[4] = quat[1];
        q[5] = quat[2];
        q[6] = quat[3];
    }
    kn_set_default_pose(w, art, q, 7);
    return art;
}

void set_inertial_mass(kn_world *w, int art, int link, double mass, double cx, double cy, double cz,
                       double ixx, double iyy, double izz) {
    const double com[3] = {cx, cy, cz};
    double I[9] = {0};
    I[0] = ixx;
    I[4] = iyy;
    I[8] = izz;
    kn_set_inertial(w, art, link, mass, com, I);
}

int add_position_actuator(kn_world *w, const char *name, int art, int link, double kp, double kd,
                          double lo, double hi, double force) {
    kn_actuator_desc d;
    kn_actuator_defaults(&d);
    d.type = KN_ACTUATOR_POSITION;
    d.articulation = art;
    d.link = link;
    d.gear = 1;
    d.kp = kp;
    d.kd = kd;
    d.ctrlMin = lo;
    d.ctrlMax = hi;
    d.forceMin = -force;
    d.forceMax = force;
    return kn_add_actuator(w, &d, name);
}

int add_sensor(kn_world *w, const char *name, int type, int art, int link) {
    kn_sensor_desc d;
    kn_sensor_defaults(&d);
    d.type = type;
    d.articulation = art;
    d.link = link;
    return kn_add_sensor(w, &d, name);
}

void apply_threaded(kn_world *w, bool threaded) {
    kn_options o;
    kn_world_get_options(w, &o);
    o.multithreaded = threaded;
    kn_world_set_options(w, &o);
}

double timestep_of(kn_world *w) {
    kn_options o;
    kn_world_get_options(w, &o);
    return o.timestep;
}

bool all_finite(const double *v, int n) {
    for (int i = 0; i < n; ++i) {
        if (!std::isfinite(v[i])) return false;
    }
    return true;
}

bool same_state(kn_world *a, kn_world *b) {
    const int nq = kn_nq(a);
    const int nv = kn_nv(a);
    if (nq != kn_nq(b) || nv != kn_nv(b)) return false;
    return std::memcmp(kn_qpos(a), kn_qpos(b), size_t(nq) * sizeof(double)) == 0 &&
           std::memcmp(kn_qvel(a), kn_qvel(b), size_t(nv) * sizeof(double)) == 0;
}

// ── scenes (geometry matches Sources/Kinetic/Scene.swift) ──────────────

kn_world *build_stack() {
    kn_world *w = kn_world_create();
    add_ground(w);
    for (int i = 0; i < 10; ++i) {
        char name[32];
        std::snprintf(name, sizeof(name), "box%d", i);
        add_free_body(w, name, KN_GEOM_BOX, 0.1, 0.1, 0.1, 500, 0, 0, 0.1 + 0.2005 * i, nullptr,
                      1.0, 0.0);
    }
    kn_compile(w);
    return w;
}

kn_world *build_cartpole() {
    kn_world *w = kn_world_create();
    add_ground(w);
    const int art = kn_add_articulation(w, "cartpole");
    const int rail = kn_add_link(w, art, -1, "cart");
    set_joint(w, art, rail, KN_JOINT_PRISMATIC, 1, 0, 0, 0, 0, 0.6, true, -2.4, 2.4, 0.1, 0.01);
    const double cart_size[3] = {0.12, 0.07, 0.05};
    kn_set_inertial_from_geom(w, art, rail, KN_GEOM_BOX, cart_size, 800);
    add_geom(w, art, rail, KN_GEOM_BOX, 0.12, 0.07, 0.05, 0, 0, 0, nullptr, 1, 0, false);

    const int pole = kn_add_link(w, art, rail, "pole");
    set_joint(w, art, pole, KN_JOINT_REVOLUTE, 0, 1, 0, 0, 0, 0, false, 0, 0, 0.002, 0.001);
    set_inertial_mass(w, art, pole, 0.4, 0, 0, 0.3, 0.012, 0.012, 0.0001);
    add_geom(w, art, pole, KN_GEOM_CAPSULE, 0.018, 0.3, 0, 0, 0, 0.3, nullptr, 1, 0, false);

    kn_actuator_desc act;
    kn_actuator_defaults(&act);
    act.type = KN_ACTUATOR_MOTOR;
    act.articulation = art;
    act.link = rail;
    act.gear = 50;
    act.ctrlMin = -1;
    act.ctrlMax = 1;
    kn_add_actuator(w, &act, "slide");
    add_sensor(w, "cart_x", KN_SENSOR_JOINT_POSITION, art, rail);
    add_sensor(w, "pole_angle", KN_SENSOR_JOINT_POSITION, art, pole);
    const double q[2] = {0, 0.08};
    kn_set_default_pose(w, art, q, 2);
    kn_compile(w);
    return w;
}

kn_world *build_chain() {
    kn_world *w = kn_world_create();
    add_ground(w, -3);
    const int art = kn_add_articulation(w, "chain");
    int parent = -1;
    const double segment = 0.12;
    constexpr int links = 20;
    for (int i = 0; i < links; ++i) {
        char name[32];
        std::snprintf(name, sizeof(name), "link%d", i);
        const int link = kn_add_link(w, art, parent, name);
        const double oz = (i == 0) ? 2.5 : -segment;
        set_joint(w, art, link, KN_JOINT_REVOLUTE, 0, 1, 0, 0, 0, oz, false, 0, 0, 0.002, 0);
        set_inertial_mass(w, art, link, 0.15, 0, 0, -segment * 0.5, 0.0008, 0.0008, 2e-5);
        add_geom(w, art, link, KN_GEOM_CAPSULE, 0.018, segment * 0.4, 0, 0, 0, -segment * 0.5,
                 nullptr, 1, 0, false);
        parent = link;
    }
    double q[links];
    for (int i = 0; i < links; ++i) q[i] = (i == 0) ? 1.4 : 0.02;
    kn_set_default_pose(w, art, q, links);
    kn_compile(w);
    return w;
}

kn_world *build_arm() {
    kn_world *w = kn_world_create();
    add_ground(w);
    const int art = kn_add_articulation(w, "arm");
    struct Seg {
        const char *name;
        double ax, ay, az;
        double ox, oy, oz;
        double length, radius, lo, hi;
    };
    const Seg segs[] = {
        {"base", 0, 0, 1, 0, 0, 0.10, 0.10, 0.075, -2.9, 2.9},
        {"shoulder", 0, 1, 0, 0, 0, 0.14, 0.22, 0.06, -1.9, 1.9},
        {"elbow", 0, 1, 0, 0, 0, 0.26, 0.20, 0.05, -2.6, 2.6},
        {"wrist1", 0, 0, 1, 0, 0, 0.22, 0.08, 0.042, -3.1, 3.1},
        {"wrist2", 0, 1, 0, 0, 0, 0.09, 0.08, 0.040, -2.0, 2.0},
        {"wrist3", 0, 0, 1, 0, 0, 0.08, 0.05, 0.036, -3.1, 3.1},
    };
    int parent = -1;
    for (const Seg &seg : segs) {
        const int link = kn_add_link(w, art, parent, seg.name);
        set_joint(w, art, link, KN_JOINT_REVOLUTE, seg.ax, seg.ay, seg.az, seg.ox, seg.oy, seg.oz,
                  true, seg.lo, seg.hi, 2.0, 0.02, 200);
        const double vol =
            kPi * seg.radius * seg.radius * seg.length + (4.0 / 3.0) * kPi * seg.radius * seg.radius * seg.radius;
        const double mass = std::max(vol * 1200.0, 0.2);
        set_inertial_mass(w, art, link, mass, 0, 0, seg.length * 0.5, mass * 0.01, mass * 0.01,
                          mass * 0.002);
        add_geom(w, art, link, KN_GEOM_CAPSULE, seg.radius, seg.length * 0.5, 0, 0, 0,
                 seg.length * 0.5, nullptr, 1, 0, true);
        char aname[64];
        std::snprintf(aname, sizeof(aname), "%s_pos", seg.name);
        add_position_actuator(w, aname, art, link, 800, 60, seg.lo, seg.hi, 200);
        parent = link;
    }
    const int tool = kn_add_link(w, art, parent, "tool");
    set_joint(w, art, tool, KN_JOINT_FIXED, 0, 0, 1, 0, 0, 0.06, false, 0, 0, 0, 0);
    const double tool_size[3] = {0.05, 0.05, 0.012};
    kn_set_inertial_from_geom(w, art, tool, KN_GEOM_BOX, tool_size, 1500);
    add_geom(w, art, tool, KN_GEOM_BOX, 0.05, 0.05, 0.012, 0, 0, 0, nullptr, 1, 0, true);
    add_sensor(w, "tool_position", KN_SENSOR_FRAME_POSITION, art, tool);
    add_sensor(w, "tool_orientation", KN_SENSOR_FRAME_ORIENTATION, art, tool);
    const double rest[6] = {0, 0.55, -1.1, 0, 0.55, 0};
    kn_set_default_pose(w, art, rest, 6);
    kn_compile(w);
    double *ctrl = kn_ctrl(w);
    const int nu = kn_nu(w);
    for (int i = 0; i < nu && i < 6; ++i) ctrl[i] = rest[i];
    return w;
}

kn_world *build_quadruped() {
    kn_world *w = kn_world_create();
    add_ground(w, 0, 1.1);
    const int art = kn_add_articulation(w, "quadruped");
    const int torso = kn_add_link(w, art, -1, "torso");
    set_joint(w, art, torso, KN_JOINT_FREE, 0, 0, 1, 0, 0, 0, false, 0, 0, 0, 0);
    const double torso_size[3] = {0.24, 0.11, 0.055};
    kn_set_inertial_from_geom(w, art, torso, KN_GEOM_BOX, torso_size, 900);
    add_geom(w, art, torso, KN_GEOM_BOX, 0.24, 0.11, 0.055, 0, 0, 0, nullptr, 1, 0, true);

    struct Leg {
        const char *name;
        double x, y;
    };
    const Leg legs[] = {{"fl", 0.19, 0.13}, {"fr", 0.19, -0.13}, {"hl", -0.19, 0.13}, {"hr", -0.19, -0.13}};

    double hip_q[4];
    axis_angle(1, 0, 0, kPi / 2, hip_q);

    for (const Leg &leg : legs) {
        char name[32];
        std::snprintf(name, sizeof(name), "%s_hip", leg.name);
        const int hip = kn_add_link(w, art, torso, name);
        set_joint(w, art, hip, KN_JOINT_REVOLUTE, 1, 0, 0, leg.x, leg.y, 0, true, -0.8, 0.8, 0.4,
                  0.01);
        const double hip_size[3] = {0.032, 0.03, 0};
        kn_set_inertial_from_geom(w, art, hip, KN_GEOM_CAPSULE, hip_size, 1000);
        add_geom(w, art, hip, KN_GEOM_CAPSULE, 0.032, 0.03, 0, 0, 0, 0, hip_q, 1, 0, true);

        std::snprintf(name, sizeof(name), "%s_thigh", leg.name);
        const int thigh = kn_add_link(w, art, hip, name);
        set_joint(w, art, thigh, KN_JOINT_REVOLUTE, 0, 1, 0, 0, 0, -0.02, true, -2.2, 1.2, 0.4, 0.01);
        set_inertial_mass(w, art, thigh, 0.9, 0, 0, -0.085, 0.008, 0.008, 0.0004);
        add_geom(w, art, thigh, KN_GEOM_CAPSULE, 0.026, 0.085, 0, 0, 0, -0.085, nullptr, 1, 0, true);

        std::snprintf(name, sizeof(name), "%s_shank", leg.name);
        const int shank = kn_add_link(w, art, thigh, name);
        set_joint(w, art, shank, KN_JOINT_REVOLUTE, 0, 1, 0, 0, 0, -0.19, true, 0.2, 2.7, 0.4, 0.01);
        set_inertial_mass(w, art, shank, 0.5, 0, 0, -0.082, 0.004, 0.004, 0.0002);
        add_geom(w, art, shank, KN_GEOM_CAPSULE, 0.020, 0.082, 0, 0, 0, -0.082, nullptr, 1, 0, true);
        add_geom(w, art, shank, KN_GEOM_SPHERE, 0.026, 0.026, 0.026, 0, 0, -0.175, nullptr, 1.3, 0,
                 true, 0.012);
        std::snprintf(name, sizeof(name), "%s_contact", leg.name);
        add_sensor(w, name, KN_SENSOR_CONTACT_NORMAL_FORCE, art, shank);

        char aname[32];
        std::snprintf(aname, sizeof(aname), "%s_hip", leg.name);
        add_position_actuator(w, aname, art, hip, 60, 2.0, -1e30, 1e30, 40);
        std::snprintf(aname, sizeof(aname), "%s_thigh", leg.name);
        add_position_actuator(w, aname, art, thigh, 60, 2.0, -1e30, 1e30, 40);
        std::snprintf(aname, sizeof(aname), "%s_shank", leg.name);
        add_position_actuator(w, aname, art, shank, 60, 2.0, -1e30, 1e30, 40);
    }
    add_sensor(w, "imu_gyro", KN_SENSOR_GYROSCOPE, art, torso);
    add_sensor(w, "imu_accel", KN_SENSOR_ACCELEROMETER, art, torso);
    kn_set_self_collision(w, art, false);

    double q[19] = {0, 0, 0.30, 1, 0, 0, 0};
    for (int i = 0; i < 4; ++i) {
        q[7 + i * 3 + 0] = 0.0;
        q[7 + i * 3 + 1] = -0.8;
        q[7 + i * 3 + 2] = 1.6;
    }
    kn_set_default_pose(w, art, q, 19);
    kn_compile(w);
    double *ctrl = kn_ctrl(w);
    for (int leg = 0; leg < 4; ++leg) {
        ctrl[leg * 3 + 0] = 0.0;
        ctrl[leg * 3 + 1] = -0.8;
        ctrl[leg * 3 + 2] = 1.6;
    }
    return w;
}

kn_world *build_dominoes() {
    kn_world *w = kn_world_create();
    add_ground(w, 0, 0.9);
    for (int i = 0; i < 60; ++i) {
        char name[32];
        std::snprintf(name, sizeof(name), "domino%d", i);
        double q[4];
        ident(q);
        if (i == 0) axis_angle(0, 1, 0, 0.22, q);
        add_free_body(w, name, KN_GEOM_BOX, 0.008, 0.045, 0.09, 900, double(i) * 0.085, 0, 0.0902, q,
                      0.7, 0.05);
    }
    kn_compile(w);
    return w;
}

kn_world *build_mixed() {
    kn_world *w = kn_world_create();
    add_ground(w);
    const int types[4] = {KN_GEOM_SPHERE, KN_GEOM_BOX, KN_GEOM_CAPSULE, KN_GEOM_CYLINDER};
    const double sizes[4][3] = {{0.09, 0.09, 0.09}, {0.08, 0.08, 0.08}, {0.06, 0.09, 0}, {0.075, 0.07, 0}};
    for (int i = 0; i < 24; ++i) {
        char name[32];
        std::snprintf(name, sizeof(name), "prim%d", i);
        const int t = types[i % 4];
        const double *s = sizes[i % 4];
        const int ring = i / 4;
        const double angle = (i % 4) * kPi / 2 + ring * 0.4;
        const double radius = 0.22 + 0.03 * ring;
        double q[4];
        axis_angle(0.3, 1, 0.2, 0.6 * i, q);
        add_free_body(w, name, t, s[0], s[1], s[2], 400, std::cos(angle) * radius,
                      std::sin(angle) * radius, 0.25 + 0.28 * ring, q, 0.8, 0.15);
    }
    kn_compile(w);
    return w;
}

const SceneSpec kScenes[] = {
    {"cartpole", 2, 3, build_cartpole},
    {"arm", 6, 8, build_arm},
    {"chain", 20, 21, build_chain},
    {"quadruped", 18, 18, build_quadruped},
    {"stack", 60, 11, build_stack},
    {"mixed", 144, 25, build_mixed},
    {"dominoes", 360, 61, build_dominoes},
};

const SceneSpec *find_scene(const char *id) {
    for (const SceneSpec &s : kScenes) {
        if (std::strcmp(s.id, id) == 0) return &s;
    }
    return nullptr;
}

BenchRow run_scene(const SceneSpec &spec, double seconds, bool threaded) {
    kn_world *w = spec.build();
    apply_threaded(w, threaded);
    const double dt = timestep_of(w);
    const int steps = std::max(1, int(seconds / dt));
    kn_step(w, std::min(kWarmup, steps));

    const auto t0 = std::chrono::steady_clock::now();
    kn_step(w, steps);
    const auto t1 = std::chrono::steady_clock::now();
    const double elapsed = std::chrono::duration<double>(t1 - t0).count();

    kn_profile p{};
    kn_get_profile(w, &p);

    BenchRow row;
    row.id = spec.id;
    row.nv = kn_nv(w);
    row.geoms = kn_ngeom(w);
    row.steps = steps;
    row.seconds = seconds;
    row.elapsed = elapsed;
    row.ms_per_step = elapsed / double(steps) * 1000.0;
    row.steps_per_s = 1000.0 / std::max(row.ms_per_step, 1e-12);
    row.realtime = seconds / std::max(elapsed, 1e-12);
    row.contacts = p.contactCount;
    row.profile = p;
    row.finite = all_finite(kn_qpos(w), kn_nq(w)) && all_finite(kn_qvel(w), kn_nv(w));

    kn_world_destroy(w);
    return row;
}

void print_table(const std::vector<BenchRow> &rows, bool threaded, double seconds) {
    std::printf("KineticCore benchmark  %.1f s of simulated time per scene\n", seconds);
    std::printf("  %s, double precision, warm caches, g++ -O2\n\n",
                threaded ? "threaded narrowphase" : "single-threaded");
    std::printf("%-12s %5s %7s %8s %10s %10s %10s %10s\n", "scene", "nv", "geoms", "steps",
                "ms/step", "steps/s", "realtime", "contacts");
    for (const BenchRow &r : rows) {
        std::printf("%-12s %5d %7d %8d %10.4f %10.0f %9.1fx %10d\n", r.id, r.nv, r.geoms, r.steps,
                    r.ms_per_step, r.steps_per_s, r.realtime, r.contacts);
    }
    std::printf("\n");
}

void print_json(const std::vector<BenchRow> &rows, bool threaded, double seconds) {
    std::printf("{\n");
    std::printf("  \"engine\": \"KineticCore\",\n");
    std::printf("  \"version\": \"%s\",\n", kn_version_string());
    std::printf("  \"seconds\": %.6f,\n", seconds);
    std::printf("  \"threaded\": %s,\n", threaded ? "true" : "false");
    std::printf("  \"scenes\": [\n");
    for (size_t i = 0; i < rows.size(); ++i) {
        const BenchRow &r = rows[i];
        std::printf("    {\"id\":\"%s\",\"nv\":%d,\"geoms\":%d,\"steps\":%d,"
                    "\"ms_per_step\":%.6f,\"steps_per_s\":%.3f,\"realtime\":%.3f,"
                    "\"contacts\":%d}",
                    r.id, r.nv, r.geoms, r.steps, r.ms_per_step, r.steps_per_s, r.realtime,
                    r.contacts);
        std::printf("%s\n", i + 1 == rows.size() ? "" : ",");
    }
    std::printf("  ],\n");
    std::printf("  \"checks\": [\n");
    for (size_t i = 0; i < g_checks.size(); ++i) {
        const Check &c = g_checks[i];
        std::printf("    {\"name\":\"%s\",\"passed\":%s,\"detail\":\"%s\"}%s\n", c.name.c_str(),
                    c.passed ? "true" : "false", c.detail.c_str(),
                    i + 1 == g_checks.size() ? "" : ",");
    }
    std::printf("  ],\n");
    std::printf("  \"failures\": %d\n", g_failures);
    std::printf("}\n");
}

const BenchRow *find_row(const std::vector<BenchRow> &rows, const char *id) {
    for (const BenchRow &r : rows) {
        if (std::strcmp(r.id, id) == 0) return &r;
    }
    return nullptr;
}

void run_checks(const std::vector<BenchRow> &rows, bool threaded) {
    for (const BenchRow &r : rows) {
        const SceneSpec *spec = find_scene(r.id);
        if (!spec) continue;
        char detail[128];
        std::snprintf(detail, sizeof(detail), "nv=%d geoms=%d", r.nv, r.geoms);
        check((std::string(r.id) + " published size").c_str(), detail,
              r.nv == spec->nv && r.geoms == spec->geoms);
        check((std::string(r.id) + " finite state").c_str(),
              r.finite ? "qpos/qvel finite" : "NaN or Inf in state", r.finite);
        check((std::string(r.id) + " positive time").c_str(),
              std::to_string(r.ms_per_step) + " ms/step", r.elapsed > 0 && r.ms_per_step > 0);
        const kn_profile &p = r.profile;
        const bool stages_ok = p.kinematics >= 0 && p.inertia >= 0 && p.bias >= 0 &&
                               p.collision >= 0 && p.constraintSetup >= 0 && p.solve >= 0 &&
                               p.integrate >= 0 && p.sensors >= 0 && p.total > 0 &&
                               std::isfinite(p.solverResidual);
        check((std::string(r.id) + " profile").c_str(),
              "total " + std::to_string(p.total) + " ms", stages_ok);
    }

    auto contacts_of = [&](const char *id) -> int {
        const BenchRow *r = find_row(rows, id);
        return r ? r->contacts : -1;
    };
    check("cartpole contact-free", "contacts " + std::to_string(contacts_of("cartpole")),
          contacts_of("cartpole") == 0);
    check("chain contact-free", "contacts " + std::to_string(contacts_of("chain")),
          contacts_of("chain") == 0);
    if (find_row(rows, "stack")) {
        check("stack has contacts", "contacts " + std::to_string(contacts_of("stack")),
              contacts_of("stack") > 0);
    }
    if (find_row(rows, "mixed")) {
        check("mixed has contacts", "contacts " + std::to_string(contacts_of("mixed")),
              contacts_of("mixed") > 0);
    }
    if (find_row(rows, "dominoes")) {
        check("dominoes has contacts", "contacts " + std::to_string(contacts_of("dominoes")),
              contacts_of("dominoes") > 0);
    }
    if (find_row(rows, "quadruped")) {
        check("quadruped has contacts", "contacts " + std::to_string(contacts_of("quadruped")),
              contacts_of("quadruped") > 0);
    }

    const BenchRow *cart = find_row(rows, "cartpole");
    const BenchRow *arm = find_row(rows, "arm");
    const BenchRow *chain = find_row(rows, "chain");
    const BenchRow *stack = find_row(rows, "stack");
    const BenchRow *mixed = find_row(rows, "mixed");
    const BenchRow *dom = find_row(rows, "dominoes");
    if (cart && stack) {
        check("cartpole cheaper than stack",
              std::to_string(cart->ms_per_step) + " vs " + std::to_string(stack->ms_per_step),
              cart->ms_per_step < stack->ms_per_step);
    }
    if (arm && stack) {
        check("arm cheaper than stack",
              std::to_string(arm->ms_per_step) + " vs " + std::to_string(stack->ms_per_step),
              arm->ms_per_step < stack->ms_per_step);
    }
    if (chain && mixed) {
        check("chain cheaper than mixed",
              std::to_string(chain->ms_per_step) + " vs " + std::to_string(mixed->ms_per_step),
              chain->ms_per_step < mixed->ms_per_step);
    }
    if (stack && dom) {
        check("stack cheaper than dominoes",
              std::to_string(stack->ms_per_step) + " vs " + std::to_string(dom->ms_per_step),
              stack->ms_per_step < dom->ms_per_step);
    }

    {
        kn_world *a = build_stack();
        kn_step(a, 3000);
        bool ordered = true;
        double max_drift = 0;
        const double *q = kn_qpos(a);
        for (int i = 0; i < 10; ++i) {
            const double z = q[i * 7 + 2];
            const double expected = 0.1 + 0.2 * i;
            const double drift = std::abs(z - expected);
            max_drift = std::max(max_drift, drift);
            if (drift > 0.02) ordered = false;
        }
        char detail[64];
        std::snprintf(detail, sizeof(detail), "max drift %.2f mm", max_drift * 1000);
        check("box stack stability", detail, ordered);
        kn_world_destroy(a);
    }

    {
        auto run_mixed = []() {
            kn_world *w = build_mixed();
            kn_step(w, 600);
            return w;
        };
        kn_world *a = run_mixed();
        kn_world *b = run_mixed();
        check("determinism", std::to_string(kn_nq(a)) + " coordinates compared", same_state(a, b));
        kn_world_destroy(a);
        kn_world_destroy(b);
    }

    {
        auto run_dominoes = [](bool mt) {
            kn_world *w = build_dominoes();
            apply_threaded(w, mt);
            kn_step(w, 400);
            return w;
        };
        kn_world *serial = run_dominoes(false);
        kn_world *mt = run_dominoes(true);
        check("threaded narrowphase determinism",
              std::to_string(kn_nq(serial)) + " coordinates compared", same_state(serial, mt));
        kn_world_destroy(serial);
        kn_world_destroy(mt);
    }

    (void)threaded;
}

void usage() {
    std::printf("Usage: kinetic-core-bench [--seconds N] [--serial] [--check] [--json] [--config] [scene...]\n");
    std::printf("Scenes: cartpole arm chain quadruped stack mixed dominoes\n");
    std::printf("\n");
    std::printf("  flag > environment > compiled default\n");
    std::printf("  --seconds / KINETIC_BENCH_SECONDS   simulated seconds (default 1)\n");
    std::printf("  --serial  / KINETIC_SERIAL          single-threaded narrowphase\n");
    std::printf("  --config                            print resolved knobs and exit\n");
    std::printf("  invalid --seconds exits 2; invalid KINETIC_BENCH_SECONDS is ignored\n");
}

const char *env_nonempty(const char *name) {
    const char *value = std::getenv(name);
    return (value && value[0] != '\0') ? value : nullptr;
}

bool parse_positive_seconds(const char *text, double *out) {
    if (!text || !text[0] || !out) return false;
    errno = 0;
    char *end = nullptr;
    double value = std::strtod(text, &end);
    if (errno != 0 || end == text || *end != '\0') return false;
    if (!std::isfinite(value) || value <= 0) return false;
    *out = value;
    return true;
}

void print_config(double seconds, const char *seconds_src,
                  bool threaded, const char *serial_src,
                  bool do_check, bool json) {
    std::printf("kinetic-core-bench configuration\n");
    std::printf("  flag > environment > compiled default\n\n");
    std::printf("  %-16s %-12s %s\n", "knob", "value", "source");
    std::printf("  %-16s %-12.1f %s\n", "seconds", seconds, seconds_src);
    std::printf("  %-16s %-12s %s\n", "serial", threaded ? "off" : "on", serial_src);
    std::printf("  %-16s %-12s %s\n", "check", do_check ? "on" : "off",
                do_check ? "--check" : "default");
    std::printf("  %-16s %-12s %s\n", "json", json ? "on" : "off",
                json ? "--json" : "default");
}

}  // namespace

int main(int argc, char **argv) {
    double seconds = 1.0;
    const char *seconds_src = "default";
    bool threaded = true;
    const char *serial_src = "default";
    bool do_check = false;
    bool dump_config = false;
    std::vector<std::string> ids;

    if (const char *env_seconds = env_nonempty("KINETIC_BENCH_SECONDS")) {
        double value = 0;
        if (parse_positive_seconds(env_seconds, &value)) {
            seconds = value;
            seconds_src = "KINETIC_BENCH_SECONDS";
        } else {
            std::fprintf(stderr, "warning: ignoring invalid KINETIC_BENCH_SECONDS='%s'\n",
                         env_seconds);
        }
    }
    if (std::getenv("KINETIC_SERIAL") != nullptr) {
        threaded = false;
        serial_src = "KINETIC_SERIAL";
    }

    for (int i = 1; i < argc; ++i) {
        const char *a = argv[i];
        if (std::strcmp(a, "--seconds") == 0) {
            if (i + 1 >= argc || std::strncmp(argv[i + 1], "--", 2) == 0) {
                std::fprintf(stderr, "error: --seconds needs a positive number\n");
                usage();
                return 2;
            }
            double value = 0;
            const char *text = argv[++i];
            if (!parse_positive_seconds(text, &value)) {
                std::fprintf(stderr, "error: invalid --seconds '%s'\n", text);
                usage();
                return 2;
            }
            seconds = value;
            seconds_src = "--seconds";
        } else if (std::strcmp(a, "--serial") == 0) {
            threaded = false;
            serial_src = "--serial";
        } else if (std::strcmp(a, "--check") == 0) {
            do_check = true;
        } else if (std::strcmp(a, "--json") == 0) {
            g_json = true;
        } else if (std::strcmp(a, "--config") == 0) {
            dump_config = true;
        } else if (std::strcmp(a, "--help") == 0 || std::strcmp(a, "-h") == 0) {
            usage();
            return 0;
        } else if (a[0] == '-') {
            std::fprintf(stderr, "unknown flag: %s\n", a);
            usage();
            return 2;
        } else {
            ids.emplace_back(a);
        }
    }

    if (dump_config) {
        print_config(seconds, seconds_src, threaded, serial_src, do_check, g_json);
        return 0;
    }

    if (ids.empty()) {
        for (const SceneSpec &s : kScenes) ids.emplace_back(s.id);
    }

    if (!g_json) {
        std::printf("KineticCore %s\n\n", kn_version_string());
        if (do_check) std::printf("Invariant checks\n\n");
    }

    std::vector<BenchRow> rows;
    rows.reserve(ids.size());
    for (const std::string &id : ids) {
        const SceneSpec *spec = find_scene(id.c_str());
        if (!spec) {
            std::fprintf(stderr, "unknown scene: %s\n", id.c_str());
            return 2;
        }
        rows.push_back(run_scene(*spec, seconds, threaded));
    }

    if (do_check) run_checks(rows, threaded);

    if (g_json) {
        print_json(rows, threaded, seconds);
    } else {
        if (do_check) std::printf("\n");
        print_table(rows, threaded, seconds);
        if (do_check) {
            if (g_failures == 0) {
                std::printf("all checks passed (%zu)\n", g_checks.size());
            } else {
                std::printf("%d check(s) failed\n", g_failures);
            }
        }
    }
    return g_failures == 0 ? 0 : 1;
}
