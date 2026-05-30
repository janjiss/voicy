package transcribe

import "testing"

func TestExtractTranscriptRemovesTimestamps(t *testing.T) {
	output := `
whisper_init_from_file_with_params_no_state: loading model
[00:00:00.000 --> 00:00:01.000]  hello world
[00:00:01.000 --> 00:00:02.000]  from voicy
`
	got := extractTranscript(output)
	want := "hello world from voicy"
	if got != want {
		t.Fatalf("expected %q, got %q", want, got)
	}
}
