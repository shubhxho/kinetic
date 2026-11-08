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
