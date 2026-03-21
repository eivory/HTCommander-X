/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using static HTCommander.Radio;

namespace HTCommander
{
    public class RepeaterBookEntry
    {
        public string Callsign { get; set; }
        public double Frequency { get; set; }
        public double InputFreq { get; set; }
        public double Latitude { get; set; }
        public double Longitude { get; set; }
        public string NearestCity { get; set; }
        public string State { get; set; }
        public string PL { get; set; }
        public string Offset { get; set; }
        public string Duplex { get; set; }
        public string Use { get; set; }
        public string Status { get; set; }
        public string County { get; set; }
        public string Landmark { get; set; }
        public string Mode { get; set; }
        public double DistanceKm { get; set; } = -1;
    }

    public class RepeaterBookRateLimitException : Exception
    {
        public RepeaterBookRateLimitException() : base("RepeaterBook API rate limit reached. Please wait and try again.") { }
    }

    public class RepeaterBookClient : IDisposable
    {
        private readonly HttpClient _http;
        private const string NorthAmericaUrl = "https://www.repeaterbook.com/api/export.php";
        private const string RowUrl = "https://www.repeaterbook.com/api/exportROW.php";

        public RepeaterBookClient()
        {
            var handler = new HttpClientHandler();
            _http = new HttpClient(handler);
            _http.Timeout = TimeSpan.FromSeconds(15);
            _http.DefaultRequestHeaders.UserAgent.ParseAdd("HTCommander-X/1.0 (https://github.com/dikei100/HTCommander-X)");
        }

        public async Task<List<RepeaterBookEntry>> SearchAsync(string country, string state, string city = null, CancellationToken ct = default)
        {
            bool isNorthAmerica = country == "United States" || country == "Canada";
            string baseUrl = isNorthAmerica ? NorthAmericaUrl : RowUrl;
            string url = $"{baseUrl}?country={Uri.EscapeDataString(country)}&state={Uri.EscapeDataString(state)}";
            if (!string.IsNullOrWhiteSpace(city))
                url += $"&city={Uri.EscapeDataString(city)}";

            var response = await _http.GetAsync(url, ct);
            if (response.StatusCode == HttpStatusCode.TooManyRequests ||
                response.StatusCode == HttpStatusCode.ServiceUnavailable)
                throw new RepeaterBookRateLimitException();

            response.EnsureSuccessStatusCode();
            string json = await response.Content.ReadAsStringAsync();
            return ParseJson(json);
        }

        private List<RepeaterBookEntry> ParseJson(string json)
        {
            var results = new List<RepeaterBookEntry>();
            if (string.IsNullOrWhiteSpace(json)) return results;

            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("results", out var arr) || arr.ValueKind != JsonValueKind.Array)
                return results;

            foreach (var el in arr.EnumerateArray())
            {
                try
                {
                    var entry = new RepeaterBookEntry
                    {
                        Callsign = GetString(el, "Callsign"),
                        Frequency = GetDouble(el, "Frequency"),
                        InputFreq = GetDouble(el, "Input Freq"),
                        Latitude = GetDouble(el, "Lat"),
                        Longitude = GetDouble(el, "Long"),
                        NearestCity = GetString(el, "Nearest City"),
                        State = GetString(el, "State"),
                        PL = GetString(el, "PL"),
                        Offset = GetString(el, "Offset"),
                        Duplex = GetString(el, "Duplex"),
                        Use = GetString(el, "Use"),
                        Status = GetString(el, "Operational Status"),
                        County = GetString(el, "County"),
                        Landmark = GetString(el, "Landmark"),
                        Mode = GetString(el, "FM Analog")
                    };

                    // Try alternative field names for status
                    if (string.IsNullOrEmpty(entry.Status))
                        entry.Status = GetString(el, "Status");

                    // If Mode field is empty, check for specific mode fields
                    if (string.IsNullOrEmpty(entry.Mode))
                    {
                        if (!string.IsNullOrEmpty(GetString(el, "DMR"))) entry.Mode = "DMR";
                        else if (!string.IsNullOrEmpty(GetString(el, "D-Star"))) entry.Mode = "D-Star";
                        else entry.Mode = "FM";
                    }
                    else
                    {
                        entry.Mode = "FM";
                    }

                    if (entry.Frequency > 0)
                        results.Add(entry);
                }
                catch { }
            }
            return results;
        }

        private static string GetString(JsonElement el, string prop)
        {
            if (el.TryGetProperty(prop, out var val))
            {
                if (val.ValueKind == JsonValueKind.String) return val.GetString() ?? "";
                if (val.ValueKind == JsonValueKind.Number) return val.GetRawText();
            }
            return "";
        }

        private static double GetDouble(JsonElement el, string prop)
        {
            if (el.TryGetProperty(prop, out var val))
            {
                if (val.ValueKind == JsonValueKind.Number && val.TryGetDouble(out double d)) return d;
                if (val.ValueKind == JsonValueKind.String && double.TryParse(val.GetString(), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out double d2)) return d2;
            }
            return 0;
        }

        public static void CalculateDistances(List<RepeaterBookEntry> entries, double lat, double lon)
        {
            foreach (var entry in entries)
            {
                if (entry.Latitude == 0 && entry.Longitude == 0)
                {
                    entry.DistanceKm = -1;
                    continue;
                }
                entry.DistanceKm = Haversine(lat, lon, entry.Latitude, entry.Longitude);
            }
        }

        private static double Haversine(double lat1, double lon1, double lat2, double lon2)
        {
            const double R = 6371.0; // Earth radius in km
            double dLat = (lat2 - lat1) * Math.PI / 180.0;
            double dLon = (lon2 - lon1) * Math.PI / 180.0;
            double a = Math.Sin(dLat / 2) * Math.Sin(dLat / 2) +
                       Math.Cos(lat1 * Math.PI / 180.0) * Math.Cos(lat2 * Math.PI / 180.0) *
                       Math.Sin(dLon / 2) * Math.Sin(dLon / 2);
            return R * 2 * Math.Atan2(Math.Sqrt(a), Math.Sqrt(1 - a));
        }

        public static List<RepeaterBookEntry> ParseCsvExport(string filePath)
        {
            var results = new List<RepeaterBookEntry>();
            string[] lines;
            try { lines = File.ReadAllLines(filePath); } catch { return results; }
            if (lines.Length < 2) return results;

            var headers = new Dictionary<string, int>();
            string[] headerParts = lines[0].Split(',');
            for (int i = 0; i < headerParts.Length; i++)
                headers[headerParts[i].Trim().Trim('"')] = i;

            for (int i = 1; i < lines.Length; i++)
            {
                try
                {
                    string[] parts = SplitCsvLine(lines[i]);
                    var entry = new RepeaterBookEntry();

                    entry.Frequency = GetCsvDouble(parts, headers, "Frequency") > 0 ?
                        GetCsvDouble(parts, headers, "Frequency") : GetCsvDouble(parts, headers, "Frequency Output");
                    entry.InputFreq = GetCsvDouble(parts, headers, "Input Freq") > 0 ?
                        GetCsvDouble(parts, headers, "Input Freq") : GetCsvDouble(parts, headers, "Frequency Input");
                    entry.Callsign = GetCsvString(parts, headers, "Callsign");
                    if (string.IsNullOrEmpty(entry.Callsign))
                        entry.Callsign = GetCsvString(parts, headers, "Description");
                    entry.NearestCity = GetCsvString(parts, headers, "Nearest City");
                    if (string.IsNullOrEmpty(entry.NearestCity))
                        entry.NearestCity = GetCsvString(parts, headers, "City");
                    entry.State = GetCsvString(parts, headers, "State");
                    entry.County = GetCsvString(parts, headers, "County");
                    entry.Latitude = GetCsvDouble(parts, headers, "Lat");
                    entry.Longitude = GetCsvDouble(parts, headers, "Long");
                    entry.Use = GetCsvString(parts, headers, "Use");
                    entry.Status = GetCsvString(parts, headers, "Operational Status");
                    if (string.IsNullOrEmpty(entry.Status))
                        entry.Status = GetCsvString(parts, headers, "Status");

                    // Tone
                    entry.PL = GetCsvString(parts, headers, "PL");
                    if (string.IsNullOrEmpty(entry.PL))
                    {
                        string plTone = GetCsvString(parts, headers, "PL Input Tone");
                        if (plTone.EndsWith(" PL")) plTone = plTone.Substring(0, plTone.Length - 3);
                        entry.PL = plTone;
                    }

                    // Duplex/Offset
                    entry.Duplex = GetCsvString(parts, headers, "Duplex");
                    entry.Offset = GetCsvString(parts, headers, "Offset");

                    // Mode
                    string mode = GetCsvString(parts, headers, "Mode");
                    if (string.IsNullOrEmpty(mode)) mode = "FM";
                    entry.Mode = mode == "FMN" ? "FM" : mode;

                    if (entry.Frequency > 0) results.Add(entry);
                }
                catch { }
            }
            return results;
        }

        private static string[] SplitCsvLine(string line)
        {
            var parts = new List<string>();
            bool inQuotes = false;
            var current = new System.Text.StringBuilder();
            foreach (char c in line)
            {
                if (c == '"') { inQuotes = !inQuotes; continue; }
                if (c == ',' && !inQuotes) { parts.Add(current.ToString().Trim()); current.Clear(); continue; }
                current.Append(c);
            }
            parts.Add(current.ToString().Trim());
            return parts.ToArray();
        }

        private static string GetCsvString(string[] parts, Dictionary<string, int> headers, string key)
        {
            if (headers.TryGetValue(key, out int idx) && idx < parts.Length)
                return parts[idx].Trim();
            return "";
        }

        private static double GetCsvDouble(string[] parts, Dictionary<string, int> headers, string key)
        {
            string val = GetCsvString(parts, headers, key);
            if (double.TryParse(val, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out double d))
                return d;
            return 0;
        }

        public static RadioChannelInfo ToRadioChannel(RepeaterBookEntry entry, int channelSlot)
        {
            // Skip unsupported modes
            string mode = (entry.Mode ?? "").Trim();
            if (mode.Equals("DMR", StringComparison.OrdinalIgnoreCase) ||
                mode.Equals("D-Star", StringComparison.OrdinalIgnoreCase) ||
                mode.Equals("P25", StringComparison.OrdinalIgnoreCase) ||
                mode.Equals("NXDN", StringComparison.OrdinalIgnoreCase) ||
                mode.Equals("System Fusion", StringComparison.OrdinalIgnoreCase))
                return null;

            var ch = new RadioChannelInfo();
            ch.channel_id = channelSlot;

            // Frequency: API Frequency = repeater output = user RX
            ch.rx_freq = (int)Math.Round(entry.Frequency * 1000000);
            ch.tx_freq = entry.InputFreq > 0 ? (int)Math.Round(entry.InputFreq * 1000000) : ch.rx_freq;
            if (ch.rx_freq == 0) return null;

            // Mode and bandwidth
            if (mode.Equals("AM", StringComparison.OrdinalIgnoreCase))
            {
                ch.rx_mod = RadioModulationType.AM;
                ch.tx_mod = RadioModulationType.AM;
                ch.bandwidth = RadioBandwidthType.WIDE;
            }
            else if (mode.Equals("FMN", StringComparison.OrdinalIgnoreCase))
            {
                ch.rx_mod = RadioModulationType.FM;
                ch.tx_mod = RadioModulationType.FM;
                ch.bandwidth = RadioBandwidthType.NARROW;
            }
            else
            {
                ch.rx_mod = RadioModulationType.FM;
                ch.tx_mod = RadioModulationType.FM;
                ch.bandwidth = RadioBandwidthType.WIDE;
            }

            // CTCSS tone (PL field, stored as Hz × 100)
            int toneValue = 0;
            string pl = (entry.PL ?? "").Trim();
            if (pl.EndsWith(" PL")) pl = pl.Substring(0, pl.Length - 3);
            if (double.TryParse(pl, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out double toneHz) && toneHz > 0)
                toneValue = (int)Math.Round(toneHz * 100);
            ch.tx_sub_audio = toneValue;
            ch.rx_sub_audio = toneValue;

            // Name (truncated to 10 chars)
            ch.name_str = (entry.Callsign ?? "").Trim();
            if (ch.name_str.Length > 10) ch.name_str = ch.name_str.Substring(0, 10);

            // Defaults
            ch.scan = false;
            ch.tx_at_max_power = true;
            ch.tx_at_med_power = false;
            ch.tx_disable = false;
            ch.mute = false;
            ch.talk_around = false;
            ch.pre_de_emph_bypass = false;

            return ch;
        }

        // Country → State/Province arrays
        public static readonly Dictionary<string, string[]> Countries = new Dictionary<string, string[]>
        {
            ["United States"] = new[] {
                "Alabama", "Alaska", "Arizona", "Arkansas", "California", "Colorado", "Connecticut",
                "Delaware", "District of Columbia", "Florida", "Georgia", "Hawaii", "Idaho", "Illinois",
                "Indiana", "Iowa", "Kansas", "Kentucky", "Louisiana", "Maine", "Maryland", "Massachusetts",
                "Michigan", "Minnesota", "Mississippi", "Missouri", "Montana", "Nebraska", "Nevada",
                "New Hampshire", "New Jersey", "New Mexico", "New York", "North Carolina", "North Dakota",
                "Ohio", "Oklahoma", "Oregon", "Pennsylvania", "Rhode Island", "South Carolina", "South Dakota",
                "Tennessee", "Texas", "Utah", "Vermont", "Virginia", "Washington", "West Virginia",
                "Wisconsin", "Wyoming", "Puerto Rico", "Guam", "U.S. Virgin Islands", "American Samoa"
            },
            ["Canada"] = new[] {
                "Alberta", "British Columbia", "Manitoba", "New Brunswick", "Newfoundland and Labrador",
                "Northwest Territories", "Nova Scotia", "Nunavut", "Ontario", "Prince Edward Island",
                "Quebec", "Saskatchewan", "Yukon"
            },
            ["Mexico"] = new string[0],
            ["United Kingdom"] = new string[0],
            ["Germany"] = new string[0],
            ["France"] = new string[0],
            ["Italy"] = new string[0],
            ["Spain"] = new string[0],
            ["Australia"] = new[] {
                "Australian Capital Territory", "New South Wales", "Northern Territory", "Queensland",
                "South Australia", "Tasmania", "Victoria", "Western Australia"
            },
            ["New Zealand"] = new string[0],
            ["Japan"] = new string[0],
            ["South Korea"] = new string[0],
            ["Brazil"] = new string[0],
            ["Argentina"] = new string[0],
            ["Chile"] = new string[0],
            ["South Africa"] = new string[0],
            ["India"] = new string[0],
            ["Thailand"] = new string[0],
            ["Philippines"] = new string[0],
            ["Indonesia"] = new string[0],
            ["Netherlands"] = new string[0],
            ["Belgium"] = new string[0],
            ["Switzerland"] = new string[0],
            ["Austria"] = new string[0],
            ["Poland"] = new string[0],
            ["Czech Republic"] = new string[0],
            ["Sweden"] = new string[0],
            ["Norway"] = new string[0],
            ["Denmark"] = new string[0],
            ["Finland"] = new string[0],
            ["Portugal"] = new string[0],
            ["Greece"] = new string[0],
            ["Turkey"] = new string[0],
            ["Israel"] = new string[0],
        };

        public void Dispose()
        {
            _http?.Dispose();
        }
    }
}
