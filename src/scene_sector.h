// Analytic annular sectors used by circular switcher cards. The outer radius
// activates the shape; a zeroed sector leaves the ordinary clip unchanged.
#pragma once
#include <math.h>
#include <stdbool.h>

struct rediwm_sector {
  double center[2];
  double radii[2]; // inner, outer
  double axis[2]; // unit vector along the middle of the wedge
  double half_angle[2]; // cosine, sine; a wedge spans no more than pi radians
};

static inline bool rediwm_sector_valid(const struct rediwm_sector *s) {
  const double *fields[] = {s->center, s->radii, s->axis, s->half_angle};
  bool zero = true;
  for (int i = 0; i < 4; i++) for (int j = 0; j < 2; j++) {
    if (!isfinite(fields[i][j])) return false;
    if (fields[i][j] != 0) zero = false;
  }
  if (s->radii[1] == 0) return zero;
  const double axis_length2 = s->axis[0] * s->axis[0] + s->axis[1] * s->axis[1];
  const double angle_length2 = s->half_angle[0] * s->half_angle[0] + s->half_angle[1] * s->half_angle[1];
  return s->radii[0] >= 0 && s->radii[1] > s->radii[0] &&
      fabs(axis_length2 - 1) < 1e-6 && fabs(angle_length2 - 1) < 1e-6 &&
      s->half_angle[0] >= 0 && s->half_angle[1] > 0;
}

// Exact signed distance to the two circular arcs and the finite radial sides.
// Fold about the wedge's axis so the nearer straight side is always the same.
// The shader's sdsector follows the same arithmetic in scene_pass.c.
static inline double rediwm_sd_sector(double px, double py, const struct rediwm_sector *s) {
  const double dx = px - s->center[0], dy = py - s->center[1];
  const double x = fabs(dx * s->axis[1] - dy * s->axis[0]);
  const double y = dx * s->axis[0] + dy * s->axis[1];
  const double radius = sqrt(dx * dx + dy * dy);
  const double cosine = s->half_angle[0], sine = s->half_angle[1];
  double along = x * sine + y * cosine;
  along = fmax(s->radii[0], fmin(s->radii[1], along));
  const double edge_x = x - sine * along, edge_y = y - cosine * along;
  double distance = sqrt(edge_x * edge_x + edge_y * edge_y);
  const bool angular_inside = y >= radius * cosine;
  if (angular_inside) {
    distance = fmin(distance, fmin(fabs(radius - s->radii[0]), fabs(radius - s->radii[1])));
    if (radius >= s->radii[0] && radius <= s->radii[1]) distance = -distance;
  }
  return distance;
}
