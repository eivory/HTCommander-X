/// Parsed APRS weather report (spec §12).
///
/// All fields are nullable — weather stations frequently omit
/// sensors they don't have, and the wire format expresses "unknown"
/// as dots or spaces in the value field. A null indicates the field
/// was absent or marked unknown.
class WeatherReport {
  /// Wind direction in degrees true (`c` field).
  final int? windDirection;

  /// Sustained one-minute wind speed in mph (`s` field).
  final int? windSpeed;

  /// Wind gust in mph — peak wind speed in the last 5 minutes
  /// (`g` field).
  final int? windGust;

  /// Temperature in degrees Fahrenheit (`t` field). May be negative.
  final int? temperatureF;

  /// Rainfall in the last hour, hundredths of an inch (`r` field).
  final int? rainLastHourHundredths;

  /// Rainfall in the last 24 hours, hundredths of an inch (`p` field).
  final int? rain24hHundredths;

  /// Rainfall since midnight, hundredths of an inch (`P` field).
  final int? rainSinceMidnightHundredths;

  /// Relative humidity, percent. Spec convention: 00 means 100%
  /// (because the field is only 2 digits). Stored here as 100 for
  /// that case so consumers don't have to re-encode the convention.
  final int? humidityPercent;

  /// Barometric pressure in tenths of a millibar / tenths of an
  /// hPascal (`b` field). Divide by 10 to get mbar.
  final int? pressureTenthsMbar;

  /// Luminosity in W/m² (`L` field, 0–999 or `l` field for ≥1000).
  final int? luminosityWm2;

  /// Snowfall in the last 24 hours, in inches (`s` field, but only
  /// when occurring after the rain fields per spec; otherwise `s`
  /// is wind speed).
  final double? snowInches;

  /// Raw rain counter (`#` field).
  final int? rainCounter;

  /// 1-letter APRS software code (e.g. `W` for WinAPRS, `X` for
  /// X-APRS, `S` for APRS+SA). Optional trailing field.
  final String? softwareCode;

  /// 2–4 char weather station unit code (e.g. `Dvs`, `RSW`, `U2k`).
  final String? unitCode;

  const WeatherReport({
    this.windDirection,
    this.windSpeed,
    this.windGust,
    this.temperatureF,
    this.rainLastHourHundredths,
    this.rain24hHundredths,
    this.rainSinceMidnightHundredths,
    this.humidityPercent,
    this.pressureTenthsMbar,
    this.luminosityWm2,
    this.snowInches,
    this.rainCounter,
    this.softwareCode,
    this.unitCode,
  });

  /// True when no fields were extracted — caller should treat as null.
  bool get isEmpty =>
      windDirection == null &&
      windSpeed == null &&
      windGust == null &&
      temperatureF == null &&
      rainLastHourHundredths == null &&
      rain24hHundredths == null &&
      rainSinceMidnightHundredths == null &&
      humidityPercent == null &&
      pressureTenthsMbar == null &&
      luminosityWm2 == null &&
      snowInches == null &&
      rainCounter == null;

  /// Parse a weather data body — the substring after the timestamp
  /// for `_` packets, or after the position+symbol for weather-
  /// over-position packets. Returns null if no weather fields could
  /// be identified.
  ///
  /// The spec is permissive: fields may appear in any order after
  /// the mandatory leading wind direction/speed/gust/temperature,
  /// and unknown values can be expressed as dots or spaces. We use
  /// case-sensitive prefix matching (`c`, `s`, `g`, `t`, `r`, `p`,
  /// `P`, `h`, `b`, `L`, `l`, `#`) to extract whatever's present.
  static WeatherReport? parseBody(String body) {
    if (body.isEmpty) return null;

    int? cDir;
    int? cSpd;
    int? cGust;
    int? cTemp;
    int? cR;
    int? cP;
    int? cPbig;
    int? cH;
    int? cB;
    int? cL;
    double? cSnow;
    int? cRainCnt;
    String? sw;
    String? unit;
    var sawAnyField = false;

    var i = 0;
    while (i < body.length) {
      final ch = body[i];
      // Each field is a tag char + a fixed number of digits/dots/
      // spaces/sign. Helper: try to extract `n` chars starting at i+1
      // and parse as int. If chars are dots or spaces, treat as null.
      int? takeInt(int n, {bool allowNeg = false}) {
        if (i + 1 + n > body.length) return null;
        final raw = body.substring(i + 1, i + 1 + n);
        // If any char is dot or space, value is unknown.
        if (raw.contains('.') || raw.contains(' ')) return null;
        if (allowNeg && raw.startsWith('-')) {
          return int.tryParse(raw);
        }
        return int.tryParse(raw);
      }

      double? takeFloat(int n) {
        if (i + 1 + n > body.length) return null;
        final raw = body.substring(i + 1, i + 1 + n);
        if (raw.contains(' ')) return null;
        return double.tryParse(raw);
      }

      switch (ch) {
        case 'c':
          cDir = takeInt(3);
          sawAnyField = true;
          i += 4;
          continue;
        case 's':
          // `s` after rain fields means snowfall (inches, 3 digits,
          // may include decimal). Otherwise it's wind speed.
          if (cR != null || cP != null || cPbig != null) {
            cSnow = takeFloat(3);
          } else {
            cSpd = takeInt(3);
          }
          sawAnyField = true;
          i += 4;
          continue;
        case 'g':
          cGust = takeInt(3);
          sawAnyField = true;
          i += 4;
          continue;
        case 't':
          // Temperature: 3 chars, may include leading '-' for
          // negatives. Spec example: t-05.
          if (i + 4 <= body.length) {
            final raw = body.substring(i + 1, i + 4);
            cTemp =
                int.tryParse(raw.startsWith('-') ? raw : raw);
          }
          sawAnyField = true;
          i += 4;
          continue;
        case 'r':
          cR = takeInt(3);
          sawAnyField = true;
          i += 4;
          continue;
        case 'p':
          cP = takeInt(3);
          sawAnyField = true;
          i += 4;
          continue;
        case 'P':
          cPbig = takeInt(3);
          sawAnyField = true;
          i += 4;
          continue;
        case 'h':
          final h = takeInt(2);
          // Spec: 00 means 100%.
          if (h == 0) {
            cH = 100;
          } else {
            cH = h;
          }
          sawAnyField = true;
          i += 3;
          continue;
        case 'b':
          cB = takeInt(5);
          sawAnyField = true;
          i += 6;
          continue;
        case 'L':
          cL = takeInt(3);
          sawAnyField = true;
          i += 4;
          continue;
        case 'l':
          // Lowercase 'l' carries luminosity ≥1000. Stored value is
          // 1000 + the 3-digit field per spec.
          final v = takeInt(3);
          if (v != null) cL = 1000 + v;
          sawAnyField = true;
          i += 4;
          continue;
        case '#':
          cRainCnt = takeInt(3);
          sawAnyField = true;
          i += 4;
          continue;
        default:
          // Trailing software code + unit code if we've already
          // matched at least one weather field. Software is a single
          // letter; unit follows in the next 2-4 chars.
          if (sawAnyField &&
              sw == null &&
              ch.codeUnitAt(0) >= 0x41 &&
              ch.codeUnitAt(0) <= 0x5A) {
            sw = ch;
            i++;
            // Take up to 4 remaining chars as unit code.
            final remaining = body.substring(i);
            if (remaining.isNotEmpty && remaining.length <= 4) {
              unit = remaining;
              i = body.length;
            }
            continue;
          }
          // Anything else means we've drifted into free text.
          i = body.length;
          break;
      }
    }

    if (!sawAnyField) return null;
    return WeatherReport(
      windDirection: cDir,
      windSpeed: cSpd,
      windGust: cGust,
      temperatureF: cTemp,
      rainLastHourHundredths: cR,
      rain24hHundredths: cP,
      rainSinceMidnightHundredths: cPbig,
      humidityPercent: cH,
      pressureTenthsMbar: cB,
      luminosityWm2: cL,
      snowInches: cSnow,
      rainCounter: cRainCnt,
      softwareCode: sw,
      unitCode: unit,
    );
  }
}
