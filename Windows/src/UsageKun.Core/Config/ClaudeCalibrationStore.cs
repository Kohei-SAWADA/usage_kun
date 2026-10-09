using System.Text.Json;

namespace UsageKun.Core;

/// Legacy cap data retained for compatibility. Windows quota no longer reads or updates it.
public sealed class ClaudeCalibration
{
    public double CapEstimate { get; set; }
    public int SampleCount { get; set; }
    public string PlanKey { get; set; } = "";
    public DateTimeOffset UpdatedAt { get; set; }
}

public sealed class ClaudeCalibrationStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    public string FilePath { get; }

    public ClaudeCalibrationStore(string? filePath = null)
    {
        FilePath = filePath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "usage_kun",
            "claude_calibration.json");
    }

    public ClaudeCalibration? Load()
    {
        try
        {
            var json = File.ReadAllText(FilePath);
            return JsonSerializer.Deserialize<ClaudeCalibration>(json, SerializerOptions);
        }
        catch
        {
            return null;
        }
    }

    public void Save(ClaudeCalibration calibration)
    {
        var directory = Path.GetDirectoryName(FilePath);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var temporaryPath = FilePath + ".tmp";
        File.WriteAllText(temporaryPath, JsonSerializer.Serialize(calibration, SerializerOptions));
        File.Move(temporaryPath, FilePath, overwrite: true);
    }
}
