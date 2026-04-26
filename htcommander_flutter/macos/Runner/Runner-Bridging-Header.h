// Bridging header — exposes vendored C libraries to Swift code in
// the Runner target. Currently just BlueZ's libsbc, used by the
// native Phase 2 RFCOMM audio plugin.

#import "sbc/sbc.h"
