// kn_api.cpp — implementation of the C ABI declared in kinetic.h.

#include "kinetic.h"

#include <cstring>
#include <string>

#include "kn_world.hpp"

using namespace kn;

namespace {

World *self(kn_world *w) { return reinterpret_cast<World *>(w); }
const World *self(const kn_world *w) { return reinterpret_cast<const World *>(w); }

Vec3 toVec(const double v[3]) { return Vec3(v[0], v[1], v[2]); }
void fromVec(const Vec3 &v, double out[3]) {
    out[0] = v.x;
    out[1] = v.y;
    out[2] = v.z;
}
Quat toQuat(const double q[4]) { return Quat(q[0], q[1], q[2], q[3]).normalized(); }
void fromQuat(const Quat &q, double out[4]) {
    out[0] = q.w;
    out[1] = q.x;
    out[2] = q.y;
    out[3] = q.z;
}

void copyString(const std::string &s, char *out, int capacity) {
    if (!out || capacity <= 0) return;
    int n = int(s.size());
    if (n > capacity - 1) n = capacity - 1;
    std::memcpy(out, s.data(), size_t(n));
    out[n] = '\0';
}

}  // namespace

extern "C" {

kn_world *kn_world_create(void) { return reinterpret_cast<kn_world *>(new World()); }
void kn_world_destroy(kn_world *w) { delete self(w); }

void kn_options_defaults(kn_options *out) {
    SimOptions d;
    out->timestep = d.timestep;
    fromVec(d.gravity, out->gravity);
    out->integrator = int(d.integrator);
    out->solverIterations = d.solverIterations;
    out->relaxationIterations = d.relaxationIterations;
    out->solverTolerance = d.solverTolerance;
    out->warmStart = d.warmStart;
    out->contactMargin = d.contactMargin;
    out->penetrationSlop = d.penetrationSlop;
    out->maxCorrectionVelocity = d.maxCorrectionVelocity;
    out->linearDamping = d.linearDamping;
    out->angularDamping = d.angularDamping;
    out->maxVelocity = d.maxVelocity;
    out->enableContacts = d.enableContacts;
    out->enableJointLimits = d.enableJointLimits;
    out->enableEqualities = d.enableEqualities;
    out->multithreaded = d.multithreaded;
}

void kn_world_get_options(const kn_world *w, kn_options *out) {
    const SimOptions &d = self(w)->options;
    out->timestep = d.timestep;
    fromVec(d.gravity, out->gravity);
    out->integrator = int(d.integrator);
    out->solverIterations = d.solverIterations;
    out->relaxationIterations = d.relaxationIterations;
    out->solverTolerance = d.solverTolerance;
    out->warmStart = d.warmStart;
    out->contactMargin = d.contactMargin;
    out->penetrationSlop = d.penetrationSlop;
    out->maxCorrectionVelocity = d.maxCorrectionVelocity;
    out->linearDamping = d.linearDamping;
    out->angularDamping = d.angularDamping;
    out->maxVelocity = d.maxVelocity;
    out->enableContacts = d.enableContacts;
    out->enableJointLimits = d.enableJointLimits;
    out->enableEqualities = d.enableEqualities;
    out->multithreaded = d.multithreaded;
}

void kn_world_set_options(kn_world *w, const kn_options *o) {
    SimOptions &d = self(w)->options;
    d.timestep = o->timestep;
    d.gravity = toVec(o->gravity);
    d.integrator = Integrator(o->integrator);
    d.solverIterations = o->solverIterations;
    d.relaxationIterations = o->relaxationIterations;
    d.solverTolerance = o->solverTolerance;
    d.warmStart = o->warmStart;
    d.contactMargin = o->contactMargin;
    d.penetrationSlop = o->penetrationSlop;
    d.maxCorrectionVelocity = o->maxCorrectionVelocity;
    d.linearDamping = o->linearDamping;
    d.angularDamping = o->angularDamping;
    d.maxVelocity = o->maxVelocity;
    d.enableContacts = o->enableContacts;
    d.enableJointLimits = o->enableJointLimits;
    d.enableEqualities = o->enableEqualities;
    d.multithreaded = o->multithreaded;
}

void kn_joint_defaults(kn_joint_desc *out) {
    std::memset(out, 0, sizeof(*out));
    out->type = KN_JOINT_FIXED;
    out->axis[2] = 1;
    out->originQuat[0] = 1;
}

void kn_geom_defaults(kn_geom_desc *out) {
    std::memset(out, 0, sizeof(*out));
    Material m;
    RenderMaterial r;
    out->type = KN_GEOM_SPHERE;
    out->size[0] = out->size[1] = out->size[2] = 0.1;
    out->localQuat[0] = 1;
    out->meshIndex = -1;
    out->friction = m.friction;
    out->torsionalFriction = m.torsionalFriction;
    out->restitution = m.restitution;
    out->stiffnessTimeConst = m.stiffnessTimeConst;
    out->dampingRatio = m.dampingRatio;
    out->margin = m.margin;
    for (int i = 0; i < 4; ++i) out->rgba[i] = r.rgba[i];
    out->metallic = r.metallic;
    out->roughness = r.roughness;
    out->emissive = r.emissive;
    out->collidable = true;
    out->visible = true;
    out->group = 1;
    out->mask = 0xFFFFFFFFu;
}

void kn_actuator_defaults(kn_actuator_desc *out) {
    std::memset(out, 0, sizeof(*out));
    out->type = KN_ACTUATOR_MOTOR;
    out->gear = 1;
    out->ctrlMin = -1e30;
    out->ctrlMax = 1e30;
    out->forceMin = -1e30;
    out->forceMax = 1e30;
}

void kn_sensor_defaults(kn_sensor_desc *out) {
    std::memset(out, 0, sizeof(*out));
    out->localQuat[0] = 1;
    out->dof = -1;
}

void kn_equality_defaults(kn_equality_desc *out) {
    std::memset(out, 0, sizeof(*out));
    out->type = KN_EQ_CONNECT;
    out->articulationB = -1;
    out->linkB = -1;
    out->relQuat[0] = 1;
    out->dof = -1;
    out->active = true;
    out->stiffnessTimeConst = 0.02;
    out->dampingRatio = 1.0;
}

// ── construction ────────────────────────────────────────────────────────

int kn_add_articulation(kn_world *w, const char *name) {
    return self(w)->addArticulation(name ? name : "");
}

int kn_add_link(kn_world *w, int art, int parent, const char *name) {
    return self(w)->addLink(art, parent, name ? name : "");
}

void kn_set_inertial(kn_world *w, int art, int link, double mass, const double com[3],
                     const double inertia[9]) {
    Mat3 I;
    for (int i = 0; i < 9; ++i) I.m[i] = inertia[i];
    self(w)->setLinkInertial(art, link, mass, toVec(com), I);
}

void kn_set_inertial_from_geom(kn_world *w, int art, int link, int geomType, const double size[3],
                               double density) {
    Vec3 s = toVec(size);
    Scalar mass = 0;
    Mat3 I;
    switch (kn_geom_type(geomType)) {
        case KN_GEOM_SPHERE:
            mass = density * Scalar(4.0 / 3.0) * kPi * s.x * s.x * s.x;
            I = inertiaSphere(mass, s.x);
            break;
        case KN_GEOM_BOX:
            mass = density * 8 * s.x * s.y * s.z;
            I = inertiaBox(mass, s);
            break;
        case KN_GEOM_CAPSULE:
            mass = density * (kPi * s.x * s.x * 2 * s.y +
                              Scalar(4.0 / 3.0) * kPi * s.x * s.x * s.x);
            I = inertiaCapsule(mass, s.x, 2 * s.y);
            break;
        case KN_GEOM_CYLINDER:
            mass = density * kPi * s.x * s.x * 2 * s.y;
            I = inertiaCylinder(mass, s.x, 2 * s.y);
            break;
        default:
            mass = density * 8 * s.x * s.y * s.z;
            I = inertiaBox(mass, s);
            break;
    }
    self(w)->setLinkInertial(art, link, mass, Vec3::zero(), I);
}

void kn_set_joint(kn_world *w, int art, int link, const kn_joint_desc *j) {
    Joint joint;
    joint.type = JointType(j->type);
    joint.axis = toVec(j->axis);
    joint.origin = Transform(toQuat(j->originQuat), toVec(j->originPos));
    joint.limited = j->limited;
    joint.lower = j->lower;
    joint.upper = j->upper;
    joint.effortLimit = j->effortLimit;
    joint.velocityLimit = j->velocityLimit;
    joint.damping = j->damping;
    joint.friction = j->friction;
    joint.armature = j->armature;
    joint.stiffness = j->stiffness;
    joint.springRef = j->springRef;
    self(w)->setJoint(art, link, joint);
}

int kn_add_geom(kn_world *w, int art, int link, const kn_geom_desc *g) {
    Geom geom;
    geom.type = GeomType(g->type);
    geom.size = toVec(g->size);
    geom.localPose = Transform(toQuat(g->localQuat), toVec(g->localPos));
    geom.meshIndex = g->meshIndex;
    geom.material.friction = g->friction;
    geom.material.torsionalFriction = g->torsionalFriction;
    geom.material.restitution = g->restitution;
    geom.material.stiffnessTimeConst = g->stiffnessTimeConst;
    geom.material.dampingRatio = g->dampingRatio;
    geom.material.margin = g->margin;
    for (int i = 0; i < 4; ++i) geom.render.rgba[i] = g->rgba[i];
    geom.render.metallic = g->metallic;
    geom.render.roughness = g->roughness;
    geom.render.emissive = g->emissive;
    geom.collidable = g->collidable;
    geom.visible = g->visible;
    geom.group = g->group;
    geom.mask = g->mask;
    return self(w)->addGeom(art, link, geom);
}

int kn_add_mesh(kn_world *w, const double *vertices, int vertexCount, const uint32_t *indices,
                int indexCount, const char *name) {
    Mesh m;
    m.name = name ? name : "";
    m.vertices.reserve(size_t(vertexCount));
    for (int i = 0; i < vertexCount; ++i)
        m.vertices.emplace_back(vertices[i * 3], vertices[i * 3 + 1], vertices[i * 3 + 2]);
    m.faces.assign(indices, indices + indexCount);
    return self(w)->addMesh(m);
}

int kn_add_actuator(kn_world *w, const kn_actuator_desc *a, const char *name) {
    Actuator act;
    act.name = name ? name : "";
    act.type = ActuatorType(a->type);
    act.articulation = a->articulation;
    act.link = a->link;
    act.gear = a->gear;
    act.kp = a->kp;
    act.kd = a->kd;
    act.ctrlMin = a->ctrlMin;
    act.ctrlMax = a->ctrlMax;
    act.forceMin = a->forceMin;
    act.forceMax = a->forceMax;
    return self(w)->addActuator(act);
}

int kn_add_sensor(kn_world *w, const kn_sensor_desc *s, const char *name) {
    Sensor sensor;
    sensor.name = name ? name : "";
    sensor.type = SensorType(s->type);
    sensor.articulation = s->articulation;
    sensor.link = s->link;
    sensor.dof = s->dof;
    sensor.localPose = Transform(toQuat(s->localQuat), toVec(s->localPos));
    sensor.noiseStdDev = s->noiseStdDev;
    sensor.bias = s->bias;
    sensor.cutoff = s->cutoff;
    return self(w)->addSensor(sensor);
}

int kn_add_equality(kn_world *w, const kn_equality_desc *e) {
    Equality eq;
    eq.type = EqualityType(e->type);
    eq.articulationA = e->articulationA;
    eq.linkA = e->linkA;
    eq.articulationB = e->articulationB;
    eq.linkB = e->linkB;
    eq.anchorA = toVec(e->anchorA);
    eq.anchorB = toVec(e->anchorB);
    eq.relPose = toQuat(e->relQuat);
    eq.target = e->target;
    eq.dof = e->dof;
    eq.active = e->active;
    eq.stiffnessTimeConst = e->stiffnessTimeConst;
    eq.dampingRatio = e->dampingRatio;
    return self(w)->addEquality(eq);
}

void kn_set_self_collision(kn_world *w, int art, bool enabled) {
    self(w)->articulationsMutable()[art].selfCollision = enabled;
}

void kn_set_articulation_enabled(kn_world *w, int art, bool enabled) {
    self(w)->articulationsMutable()[art].enabled = enabled;
}

void kn_compile(kn_world *w) { self(w)->compile(); }
bool kn_is_compiled(const kn_world *w) { return self(w)->isCompiled(); }

// ── sizes ───────────────────────────────────────────────────────────────

int kn_nq(const kn_world *w) { return self(w)->nq(); }
int kn_nv(const kn_world *w) { return self(w)->nv(); }
int kn_nu(const kn_world *w) { return self(w)->nu(); }
int kn_nsensordata(const kn_world *w) { return self(w)->nsensordata(); }
int kn_narticulation(const kn_world *w) { return int(self(w)->articulations().size()); }
int kn_nlink(const kn_world *w) { return self(w)->linkCount(); }
int kn_ngeom(const kn_world *w) { return int(self(w)->geoms().size()); }
int kn_nmesh(const kn_world *w) { return int(self(w)->meshes().size()); }
int kn_link_count(const kn_world *w, int art) {
    return int(self(w)->articulations()[art].links.size());
}
int kn_articulation_nq(const kn_world *w, int art) { return self(w)->articulations()[art].nq; }
int kn_articulation_nv(const kn_world *w, int art) { return self(w)->articulations()[art].nv; }
int kn_articulation_qoffset(const kn_world *w, int art) {
    return self(w)->articulations()[art].qOffset;
}
int kn_articulation_voffset(const kn_world *w, int art) {
    return self(w)->articulations()[art].vOffset;
}

// ── state ───────────────────────────────────────────────────────────────

double *kn_qpos(kn_world *w) { return self(w)->qpos.data(); }
double *kn_qvel(kn_world *w) { return self(w)->qvel.data(); }
double *kn_qacc(kn_world *w) { return self(w)->qacc.data(); }
double *kn_ctrl(kn_world *w) { return self(w)->ctrl.data(); }
double *kn_actuator_force(kn_world *w) { return self(w)->actuatorForce.data(); }
double *kn_sensor_data(kn_world *w) { return self(w)->sensorData.data(); }
double *kn_qfrc_applied(kn_world *w) { return self(w)->qfrcApplied.data(); }
double kn_time(const kn_world *w) { return self(w)->time; }
void kn_set_time(kn_world *w, double t) { self(w)->time = t; }

void kn_reset(kn_world *w) { self(w)->resetState(); }
void kn_step(kn_world *w, int count) { self(w)->stepMany(count); }
void kn_forward(kn_world *w) { self(w)->forward(); }

void kn_set_default_pose(kn_world *w, int art, const double *q, int count) {
    VecX v(q, q + count);
    self(w)->setDefaultPose(art, v);
}

void kn_apply_force(kn_world *w, int art, int link, const double force[3],
                    const double worldPoint[3]) {
    self(w)->applyForceAtPoint(art, link, toVec(force), toVec(worldPoint));
}

void kn_apply_torque(kn_world *w, int art, int link, const double torque[3]) {
    self(w)->applyTorque(art, link, toVec(torque));
}

void kn_clear_applied_forces(kn_world *w) { self(w)->clearAppliedForces(); }

int kn_state_size(const kn_world *w) { return self(w)->nq() + self(w)->nv() + 1; }

int kn_save_state(const kn_world *w, double *out, int capacity) {
    VecX s;
    self(w)->saveState(s);
    int n = int(s.size());
    if (capacity < n) return -n;
    std::memcpy(out, s.data(), sizeof(double) * size_t(n));
    return n;
}

void kn_load_state(kn_world *w, const double *in, int count) {
    VecX s(in, in + count);
    self(w)->loadState(s);
}

// ── introspection ───────────────────────────────────────────────────────

void kn_link_poses(const kn_world *w, double *out) {
    const World *world = self(w);
    int idx = 0;
    for (const Articulation &art : world->articulations())
        for (const Link &l : art.links) {
            fromVec(l.pose.pos, out + idx * 7);
            fromQuat(l.pose.rot, out + idx * 7 + 3);
            ++idx;
        }
}

void kn_geom_poses(const kn_world *w, double *out) {
    const World *world = self(w);
    const auto &geoms = world->geoms();
    for (size_t i = 0; i < geoms.size(); ++i) {
        const Geom &g = geoms[i];
        Transform pose = world->articulations()[g.articulation].links[g.link].pose * g.localPose;
        fromVec(pose.pos, out + i * 7);
        fromQuat(pose.rot, out + i * 7 + 3);
    }
}

void kn_geom_info(const kn_world *w, int gi, kn_geom_desc *out) {
    kn_geom_defaults(out);
    const Geom &g = self(w)->geoms()[gi];
    out->type = int(g.type);
    fromVec(g.size, out->size);
    fromVec(g.localPose.pos, out->localPos);
    fromQuat(g.localPose.rot, out->localQuat);
    out->meshIndex = g.meshIndex;
    out->friction = g.material.friction;
    out->torsionalFriction = g.material.torsionalFriction;
    out->restitution = g.material.restitution;
    out->stiffnessTimeConst = g.material.stiffnessTimeConst;
    out->dampingRatio = g.material.dampingRatio;
    out->margin = g.material.margin;
    for (int i = 0; i < 4; ++i) out->rgba[i] = g.render.rgba[i];
    out->metallic = g.render.metallic;
    out->roughness = g.render.roughness;
    out->emissive = g.render.emissive;
    out->collidable = g.collidable;
    out->visible = g.visible;
    out->group = g.group;
    out->mask = g.mask;
}

int kn_geom_articulation(const kn_world *w, int gi) { return self(w)->geoms()[gi].articulation; }
int kn_geom_link(const kn_world *w, int gi) { return self(w)->geoms()[gi].link; }

int kn_mesh_vertex_count(const kn_world *w, int mi) {
    return int(self(w)->meshes()[mi].vertices.size());
}
int kn_mesh_index_count(const kn_world *w, int mi) { return int(self(w)->meshes()[mi].faces.size()); }

void kn_mesh_data(const kn_world *w, int mi, double *vertices, uint32_t *indices) {
    const Mesh &m = self(w)->meshes()[mi];
    if (vertices)
        for (size_t i = 0; i < m.vertices.size(); ++i) fromVec(m.vertices[i], vertices + i * 3);
    if (indices && !m.faces.empty())
        std::memcpy(indices, m.faces.data(), sizeof(uint32_t) * m.faces.size());
}

int kn_contact_count(const kn_world *w) { return int(self(w)->contactForces().size()); }

int kn_get_contacts(const kn_world *w, kn_contact *out, int capacity) {
    const auto &forces = self(w)->contactForces();
    int n = std::min(int(forces.size()), capacity);
    for (int i = 0; i < n; ++i) {
        fromVec(forces[i].point, out[i].point);
        fromVec(forces[i].normal, out[i].normal);
        fromVec(forces[i].force, out[i].force);
        out[i].depth = forces[i].depth;
        out[i].geomA = forces[i].geomA;
        out[i].geomB = forces[i].geomB;
    }
    return n;
}

void kn_get_profile(const kn_world *w, kn_profile *out) {
    const StepProfile &p = self(w)->profile();
    out->kinematics = p.kinematics;
    out->inertia = p.inertia;
    out->bias = p.bias;
    out->collision = p.collision;
    out->constraintSetup = p.constraintSetup;
    out->solve = p.solve;
    out->integrate = p.integrate;
    out->sensors = p.sensors;
    out->total = p.total;
    out->contactCount = p.contactCount;
    out->constraintCount = p.constraintCount;
    out->broadphasePairs = p.broadphasePairs;
    out->solverIterations = p.solverIterations;
    out->solverResidual = p.solverResidual;
}

void kn_link_name(const kn_world *w, int art, int link, char *out, int capacity) {
    copyString(self(w)->articulations()[art].links[link].name, out, capacity);
}

void kn_articulation_name(const kn_world *w, int art, char *out, int capacity) {
    copyString(self(w)->articulations()[art].name, out, capacity);
}

int kn_find_articulation(const kn_world *w, const char *name) {
    return self(w)->findArticulation(name ? name : "");
}
int kn_find_link(const kn_world *w, int art, const char *name) {
    return self(w)->findLink(art, name ? name : "");
}
int kn_find_actuator(const kn_world *w, const char *name) {
    return self(w)->findActuator(name ? name : "");
}

int kn_link_joint_type(const kn_world *w, int art, int link) {
    return int(self(w)->articulations()[art].links[link].joint.type);
}
int kn_link_joint_qindex(const kn_world *w, int art, int link) {
    return self(w)->articulations()[art].links[link].joint.qIndex;
}
int kn_link_joint_vindex(const kn_world *w, int art, int link) {
    return self(w)->articulations()[art].links[link].joint.vIndex;
}
void kn_link_joint_limits(const kn_world *w, int art, int link, double *lower, double *upper,
                          bool *limited) {
    const Joint &j = self(w)->articulations()[art].links[link].joint;
    if (lower) *lower = j.lower;
    if (upper) *upper = j.upper;
    if (limited) *limited = j.limited;
}
double kn_link_mass(const kn_world *w, int art, int link) {
    return self(w)->articulations()[art].links[link].mass;
}
int kn_link_parent(const kn_world *w, int art, int link) {
    return self(w)->articulations()[art].links[link].parent;
}

void kn_actuator_info(const kn_world *w, int ai, kn_actuator_desc *out) {
    kn_actuator_defaults(out);
    const Actuator &a = self(w)->actuators()[ai];
    out->type = int(a.type);
    out->articulation = a.articulation;
    out->link = a.link;
    out->gear = a.gear;
    out->kp = a.kp;
    out->kd = a.kd;
    out->ctrlMin = a.ctrlMin;
    out->ctrlMax = a.ctrlMax;
    out->forceMin = a.forceMin;
    out->forceMax = a.forceMax;
}

void kn_actuator_name(const kn_world *w, int ai, char *out, int capacity) {
    const auto &actuators = self(w)->actuators();
    copyString(ai >= 0 && ai < int(actuators.size()) ? actuators[ai].name : std::string(), out,
               capacity);
}

int kn_global_link_index(const kn_world *w, int art, int link) {
    return self(w)->linkGlobalIndex(art, link);
}

void kn_link_velocities(const kn_world *w, double *out) {
    const World *world = self(w);
    int idx = 0;
    for (const Articulation &art : world->articulations())
        for (const Link &l : art.links) {
            fromVec(l.velocity.ang, out + idx * 6);
            // Report the velocity of the link origin, which is what a caller
            // means by "how fast is this link moving"; the spatial vector's
            // linear part is about the world origin and would be surprising.
            fromVec(l.velocity.pointVelocity(l.pose.pos), out + idx * 6 + 3);
            ++idx;
        }
}

double kn_kinetic_energy(const kn_world *w) { return self(w)->kineticEnergy(); }
double kn_potential_energy(const kn_world *w) { return self(w)->potentialEnergy(); }
double kn_total_mass(const kn_world *w) { return self(w)->totalMass(); }
void kn_center_of_mass(const kn_world *w, double out[3]) { fromVec(self(w)->centerOfMass(), out); }
void kn_linear_momentum(const kn_world *w, double out[3]) {
    fromVec(self(w)->linearMomentum(), out);
}
void kn_angular_momentum(const kn_world *w, double out[3]) {
    fromVec(self(w)->angularMomentum(), out);
}

kn_ray_hit kn_raycast(const kn_world *w, const double origin[3], const double dir[3],
                      double maxDistance, uint32_t mask, int ignoreArticulation) {
    RayHit h = self(w)->raycast(toVec(origin), toVec(dir), maxDistance, mask, ignoreArticulation);
    kn_ray_hit out;
    out.hit = h.hit;
    out.distance = h.distance;
    fromVec(h.point, out.point);
    fromVec(h.normal, out.normal);
    out.geom = h.geom;
    out.articulation = h.articulation;
    out.link = h.link;
    return out;
}

void kn_point_jacobian(const kn_world *w, int art, int link, const double worldPoint[3],
                       double *out) {
    self(w)->pointJacobian(art, link, toVec(worldPoint), out);
}

void kn_mass_matrix(const kn_world *w, int art, double *out) {
    const ArticulationCache &c = self(w)->cache(art);
    int n = self(w)->articulations()[art].nv;
    for (int i = 0; i < n; ++i)
        for (int j = 0; j < n; ++j) out[i * n + j] = c.massMatrixRaw(i, j);
}

const char *kn_version_string(void) { return "Kinetic 1.0.0"; }

}  // extern "C"
