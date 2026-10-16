<#
.SYNOPSIS
  Render early-reader words to 16 kHz / 16-bit / mono WAVs with Windows
  text-to-speech (System.Speech), for godot/tests/tts_match_test.gd.
  No microphone or dataset needed. Output is generated, so it is git-ignored.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools/make_tts_clips.ps1
  powershell -ExecutionPolicy Bypass -File tools/make_tts_clips.ps1 -OutDir C:\tmp\clips -Rate -2
#>
param(
    [string]$OutDir = (Join-Path $PSScriptRoot "..\godot\tests\tts_clips"),
    # Target words (sound-alike pairs on purpose: cat/hat, sun/run, go/no/two).
    [string[]]$Words = @("cat", "hat", "dog", "sun", "red", "big", "run", "go", "no", "two", "see", "the"),
    # Speech that is not an on-screen word: nothing should fire.
    [string[]]$Other = @("um", "banana", "what's that"),
    # Several words in one breath: each must fire.
    [string[]]$Multi = @("cat dog"),
    # SpeechSynthesizer rate, -10..10 (0 = normal; kids' pace is slower).
    [int]$Rate = 0,
    # Optional installed voice name (see: (New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices()).
    [string]$Voice = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Speech

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(
    16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)

function Render([string]$text, [string]$file) {
    $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        if ($Voice -ne "") { $s.SelectVoice($Voice) }
        $s.Rate = $Rate
        $s.SetOutputToWaveFile($file, $fmt)
        $s.Speak($text)
    } finally {
        $s.Dispose()
    }
}

# File name encodes the role so the test needs no manifest:
#   word_<w>.wav, other_<text>.wav, multi_<w1>_<w2>.wav
function Slug([string]$t) { ($t.ToLower() -replace "[^a-z0-9]+", "_").Trim("_") }

$n = 0
foreach ($w in $Words) { Render $w (Join-Path $OutDir ("word_" + (Slug $w) + ".wav")); $n++ }
foreach ($t in $Other) { Render $t (Join-Path $OutDir ("other_" + (Slug $t) + ".wav")); $n++ }
foreach ($t in $Multi) { Render $t (Join-Path $OutDir ("multi_" + (Slug $t) + ".wav")); $n++ }

$voiceName = (New-Object System.Speech.Synthesis.SpeechSynthesizer).Voice.Name
if ($Voice -ne "") { $voiceName = $Voice }
Write-Output "wrote $n clips to $OutDir (voice: $voiceName, rate $Rate)"
