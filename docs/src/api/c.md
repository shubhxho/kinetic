# C API

`Sources/KineticCore/include/kinetic.h` is the stable ABI. Everything is plain
data: no C++ types, no exceptions, no ownership beyond create/destroy.

```c
#include "kinetic.h"
```

Angles are radians, lengths metres, masses kilograms, time seconds.

## Lifecycle

```c
kn_world *w = kn_world_create();
/* ... build the model ... */
kn_compile(w);
kn_step(w, 1000);
kn_world_destroy(w);
```

## A complete example

```c
#include "kinetic.h"
#include <stdio.h>

int main(void) {
    kn_world *w = kn_world_create();

    /* ground: a fixed articulation carrying an infinite plane */
    int ground = kn_add_articulation(w, "ground");
    int gl = kn_add_link(w, ground, -1, "plane");
    kn_joint_desc fixed;
    kn_joint_defaults(&fixed);
    fixed.type = KN_JOINT_FIXED;
    kn_set_joint(w, ground, gl, &fixed);

    kn_geom_desc plane;
    kn_geom_defaults(&plane);
    plane.type = KN_GEOM_PLANE;
    kn_add_geom(w, ground, gl, &plane);

    /* a falling ball */
    int ball = kn_add_articulation(w, "ball");
    int bl = kn_add_link(w, ball, -1, "ball");
    kn_joint_desc freeJoint;
    kn_joint_defaults(&freeJoint);
    freeJoint.type = KN_JOINT_FREE;
    kn_set_joint(w, ball, bl, &freeJoint);

    double size[3] = {0.2, 0, 0};
    kn_set_inertial_from_geom(w, ball, bl, KN_GEOM_SPHERE, size, 500.0);

    kn_geom_desc sphere;
    kn_geom_defaults(&sphere);
    sphere.type = KN_GEOM_SPHERE;
    sphere.size[0] = 0.2;
    kn_add_geom(w, ball, bl, &sphere);

    double start[7] = {0, 0, 1, 1, 0, 0, 0};
    kn_set_default_pose(w, ball, start, 7);

    kn_compile(w);
    kn_step(w, 1500);

    printf("resting height: %.6f m\n", kn_qpos(w)[2]);   /* 0.200000 */

    kn_profile p;
    kn_get_profile(w, &p);
    printf("%.4f ms/step, %d contacts\n", p.total, p.contactCount);

    kn_world_destroy(w);
    return 0;
}
```

```bash
clang -std=c11 example.c \
  -ISources/KineticCore/include \
  -L.build/release -lKineticCore -lc++ -o example
```

## Descriptors

Every descriptor has a `_defaults` function. **Always call it** — new fields will
be added, and zero-initialising by hand will silently produce different physics
when you update.

```c
kn_options_defaults(&options);
kn_joint_defaults(&joint);
kn_geom_defaults(&geom);
kn_actuator_defaults(&actuator);
kn_sensor_defaults(&sensor);
kn_equality_defaults(&equality);
```

## Reference

### Model construction

```c
int  kn_add_articulation(kn_world *, const char *name);
int  kn_add_link(kn_world *, int articulation, int parent, const char *name);
void kn_set_inertial(kn_world *, int art, int link, double mass,
                     const double com[3], const double inertia[9]);
void kn_set_inertial_from_geom(kn_world *, int art, int link, int geomType,
                               const double size[3], double density);
void kn_set_joint(kn_world *, int art, int link, const kn_joint_desc *);
int  kn_add_geom(kn_world *, int art, int link, const kn_geom_desc *);
int  kn_add_mesh(kn_world *, const double *vertices, int vertexCount,
                 const uint32_t *indices, int indexCount, const char *name);
int  kn_add_actuator(kn_world *, const kn_actuator_desc *, const char *name);
int  kn_add_sensor(kn_world *, const kn_sensor_desc *, const char *name);
int  kn_add_equality(kn_world *, const kn_equality_desc *);
void kn_set_self_collision(kn_world *, int articulation, bool enabled);
void kn_set_articulation_enabled(kn_world *, int articulation, bool enabled);
void kn_compile(kn_world *);
bool kn_is_compiled(const kn_world *);
```

### Sizes

```c
int kn_nq(const kn_world *);            int kn_nv(const kn_world *);
int kn_nu(const kn_world *);            int kn_nsensordata(const kn_world *);
int kn_narticulation(const kn_world *); int kn_nlink(const kn_world *);
int kn_ngeom(const kn_world *);         int kn_nmesh(const kn_world *);
int kn_link_count(const kn_world *, int articulation);
int kn_articulation_nq(const kn_world *, int articulation);
int kn_articulation_nv(const kn_world *, int articulation);
int kn_articulation_qoffset(const kn_world *, int articulation);
int kn_articulation_voffset(const kn_world *, int articulation);
```

### State

Pointers into engine storage, valid until the next `kn_compile`.

```c
double *kn_qpos(kn_world *);            double *kn_qvel(kn_world *);
double *kn_qacc(kn_world *);            double *kn_ctrl(kn_world *);
double *kn_actuator_force(kn_world *);  double *kn_sensor_data(kn_world *);
double *kn_qfrc_applied(kn_world *);

double kn_time(const kn_world *);
void   kn_set_time(kn_world *, double);
void   kn_reset(kn_world *);
void   kn_step(kn_world *, int count);
void   kn_forward(kn_world *);
void   kn_set_default_pose(kn_world *, int articulation, const double *q, int count);

void kn_apply_force(kn_world *, int art, int link,
                    const double force[3], const double worldPoint[3]);
void kn_apply_torque(kn_world *, int art, int link, const double torque[3]);
void kn_clear_applied_forces(kn_world *);

int  kn_state_size(const kn_world *);
int  kn_save_state(const kn_world *, double *out, int capacity);
void kn_load_state(kn_world *, const double *in, int count);
```

### Introspection

```c
void kn_link_poses(const kn_world *, double *out);   /* 7 per link: xyz + wxyz */
void kn_geom_poses(const kn_world *, double *out);   /* 7 per geom */
void kn_geom_info(const kn_world *, int geom, kn_geom_desc *out);
int  kn_geom_articulation(const kn_world *, int geom);
int  kn_geom_link(const kn_world *, int geom);

int  kn_mesh_vertex_count(const kn_world *, int mesh);
int  kn_mesh_index_count(const kn_world *, int mesh);
void kn_mesh_data(const kn_world *, int mesh, double *vertices, uint32_t *indices);

int  kn_contact_count(const kn_world *);
int  kn_get_contacts(const kn_world *, kn_contact *out, int capacity);
void kn_get_profile(const kn_world *, kn_profile *out);

double kn_kinetic_energy(const kn_world *);
double kn_potential_energy(const kn_world *);
double kn_total_mass(const kn_world *);
void   kn_center_of_mass(const kn_world *, double out[3]);
void   kn_linear_momentum(const kn_world *, double out[3]);
void   kn_angular_momentum(const kn_world *, double out[3]);

kn_ray_hit kn_raycast(const kn_world *, const double origin[3], const double dir[3],
                      double maxDistance, uint32_t mask, int ignoreArticulation);
void kn_point_jacobian(const kn_world *, int art, int link,
                       const double worldPoint[3], double *out);   /* 3 × nv */
void kn_mass_matrix(const kn_world *, int articulation, double *out); /* nv × nv */

const char *kn_version_string(void);
```

## Binding from other languages

The header is deliberately plain enough for automatic binding generators.

**Python (ctypes)**

```python
import ctypes
kn = ctypes.CDLL("libKineticCore.dylib")
kn.kn_world_create.restype = ctypes.c_void_p
kn.kn_qpos.restype = ctypes.POINTER(ctypes.c_double)

world = kn.kn_world_create()
# ... build, compile ...
kn.kn_step(ctypes.c_void_p(world), 1000)
print(kn.kn_qpos(ctypes.c_void_p(world))[2])
```

The same shape works for Rust's `bindgen`, Zig's `@cImport`, Go's cgo and Julia's
`ccall`.

## Thread safety

A `kn_world` is not thread-safe. Serialise access, or give each thread its own
world. The engine's internal threading (the narrowphase) is contained inside
`kn_step` and does not escape.
