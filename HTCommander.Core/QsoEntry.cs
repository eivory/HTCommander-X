/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;

namespace HTCommander
{
    public class QsoEntry
    {
        public DateTime StartTime { get; set; }
        public DateTime EndTime { get; set; }
        public string Callsign { get; set; }
        public double FrequencyMHz { get; set; }
        public string Mode { get; set; }
        public string Band { get; set; }
        public string RstSent { get; set; }
        public string RstReceived { get; set; }
        public string MyCallsign { get; set; }
        public string Notes { get; set; }

        public static string GetBand(double freqMHz)
        {
            if (freqMHz >= 1.8 && freqMHz <= 2.0) return "160m";
            if (freqMHz >= 3.5 && freqMHz <= 4.0) return "80m";
            if (freqMHz >= 5.3 && freqMHz <= 5.4) return "60m";
            if (freqMHz >= 7.0 && freqMHz <= 7.3) return "40m";
            if (freqMHz >= 10.1 && freqMHz <= 10.15) return "30m";
            if (freqMHz >= 14.0 && freqMHz <= 14.35) return "20m";
            if (freqMHz >= 18.068 && freqMHz <= 18.168) return "17m";
            if (freqMHz >= 21.0 && freqMHz <= 21.45) return "15m";
            if (freqMHz >= 24.89 && freqMHz <= 24.99) return "12m";
            if (freqMHz >= 28.0 && freqMHz <= 29.7) return "10m";
            if (freqMHz >= 50.0 && freqMHz <= 54.0) return "6m";
            if (freqMHz >= 144.0 && freqMHz <= 148.0) return "2m";
            if (freqMHz >= 222.0 && freqMHz <= 225.0) return "1.25m";
            if (freqMHz >= 420.0 && freqMHz <= 450.0) return "70cm";
            if (freqMHz >= 902.0 && freqMHz <= 928.0) return "33cm";
            if (freqMHz >= 1240.0 && freqMHz <= 1300.0) return "23cm";
            return "";
        }
    }
}
