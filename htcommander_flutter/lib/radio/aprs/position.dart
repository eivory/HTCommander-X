import 'coordinate_set.dart';

/// Represents an APRS position with coordinates, course, speed, altitude,
/// and grid square.
class Position {
  CoordinateSet coordinateSet;
  int ambiguity;
  int course;
  int speed;
  int altitude;
  String gridsquare;

  Position()
      : coordinateSet = CoordinateSet(),
        ambiguity = 0,
        course = 0,
        speed = 0,
        altitude = 0,
        gridsquare = '';

  /// Resets all fields to defaults.
  void clear() {
    coordinateSet.clear();
    ambiguity = 0;
    course = 0;
    speed = 0;
    altitude = 0;
    gridsquare = '';
  }

  /// Returns true if the underlying coordinate set is valid.
  bool get isValid => coordinateSet.isValid;
}
