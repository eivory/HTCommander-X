/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.Text;
using System.Collections.Generic;
using System.Globalization;

namespace HTCommander
{
    public static class AdifExport
    {
        public static string Export(List<QsoEntry> entries)
        {
            var sb = new StringBuilder();

            // ADIF header
            sb.AppendLine("ADIF Export from HTCommander-X");
            sb.AppendLine($"Generated: {DateTime.UtcNow:yyyy-MM-dd HH:mm} UTC");
            sb.AppendLine();
            WriteField(sb, "ADIF_VER", "3.1.4");
            WriteField(sb, "PROGRAMID", "HTCommander-X");
            sb.AppendLine();
            sb.AppendLine("<EOH>");
            sb.AppendLine();

            foreach (var qso in entries)
            {
                if (string.IsNullOrWhiteSpace(qso.Callsign)) continue;

                WriteField(sb, "CALL", qso.Callsign);
                WriteField(sb, "QSO_DATE", qso.StartTime.ToString("yyyyMMdd"));
                WriteField(sb, "TIME_ON", qso.StartTime.ToString("HHmm"));
                if (qso.EndTime > qso.StartTime)
                {
                    WriteField(sb, "QSO_DATE_OFF", qso.EndTime.ToString("yyyyMMdd"));
                    WriteField(sb, "TIME_OFF", qso.EndTime.ToString("HHmm"));
                }
                if (qso.FrequencyMHz > 0)
                    WriteField(sb, "FREQ", qso.FrequencyMHz.ToString("F6", CultureInfo.InvariantCulture));
                if (!string.IsNullOrEmpty(qso.Mode))
                    WriteField(sb, "MODE", qso.Mode);
                if (!string.IsNullOrEmpty(qso.Band))
                    WriteField(sb, "BAND", qso.Band);
                if (!string.IsNullOrEmpty(qso.RstSent))
                    WriteField(sb, "RST_SENT", qso.RstSent);
                if (!string.IsNullOrEmpty(qso.RstReceived))
                    WriteField(sb, "RST_RCVD", qso.RstReceived);
                if (!string.IsNullOrEmpty(qso.MyCallsign))
                    WriteField(sb, "STATION_CALLSIGN", qso.MyCallsign);
                if (!string.IsNullOrEmpty(qso.Notes))
                    WriteField(sb, "COMMENT", qso.Notes);

                sb.AppendLine("<EOR>");
                sb.AppendLine();
            }

            return sb.ToString();
        }

        private static void WriteField(StringBuilder sb, string tag, string value)
        {
            if (string.IsNullOrEmpty(value)) return;
            sb.Append($"<{tag}:{value.Length}>{value} ");
        }
    }
}
