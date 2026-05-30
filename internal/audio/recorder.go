package audio

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"math"
	"os"
	"path/filepath"
	"sync"

	"github.com/gen2brain/malgo"
)

const (
	defaultSampleRate = 16000
	defaultChannels   = 1
)

type Recorder struct {
	mu        sync.Mutex
	ctx       *malgo.AllocatedContext
	device    *malgo.Device
	buffer    bytes.Buffer
	recording bool

	peakMu      sync.Mutex
	currentPeak float64
	sessionPeak float64
	sumSquares  float64
	sampleCount int64
}

func NewRecorder() *Recorder {
	return &Recorder{}
}

func (r *Recorder) Start(_ context.Context) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.recording {
		return nil
	}

	r.buffer.Reset()
	r.peakMu.Lock()
	r.currentPeak = 0
	r.sessionPeak = 0
	r.sumSquares = 0
	r.sampleCount = 0
	r.peakMu.Unlock()

	ctx, err := malgo.InitContext(nil, malgo.ContextConfig{}, func(message string) {})
	if err != nil {
		return err
	}

	config := malgo.DefaultDeviceConfig(malgo.Capture)
	config.Capture.Format = malgo.FormatS16
	config.Capture.Channels = defaultChannels
	config.SampleRate = defaultSampleRate

	device, err := malgo.InitDevice(ctx.Context, config, malgo.DeviceCallbacks{
		Data: func(_, input []byte, _ uint32) {
			if len(input) == 0 {
				return
			}
			r.mu.Lock()
			if r.recording {
				_, _ = r.buffer.Write(input)
			}
			r.mu.Unlock()
			r.updatePeak(input)
		},
	})
	if err != nil {
		ctx.Free()
		return err
	}

	if err := device.Start(); err != nil {
		device.Uninit()
		ctx.Free()
		return err
	}

	r.ctx = ctx
	r.device = device
	r.recording = true
	return nil
}

func (r *Recorder) Stop(_ context.Context) (string, error) {
	r.mu.Lock()
	if !r.recording {
		r.mu.Unlock()
		return "", errors.New("recorder is not running")
	}

	device := r.device
	ctx := r.ctx
	pcm := append([]byte(nil), r.buffer.Bytes()...)
	r.device = nil
	r.ctx = nil
	r.recording = false
	r.buffer.Reset()
	r.mu.Unlock()

	if device != nil {
		_ = device.Stop()
		device.Uninit()
	}
	if ctx != nil {
		ctx.Free()
	}

	if len(pcm) == 0 {
		return "", errors.New("recording did not capture any audio")
	}

	path := filepath.Join(os.TempDir(), "voicy-recording-*.wav")
	file, err := os.CreateTemp("", filepath.Base(path))
	if err != nil {
		return "", err
	}
	defer file.Close()

	if err := writePCM16WAV(file, pcm, defaultSampleRate, defaultChannels); err != nil {
		_ = os.Remove(file.Name())
		return "", err
	}

	return file.Name(), nil
}

func (r *Recorder) IsRecording() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.recording
}

// CurrentPeak returns the highest absolute sample value seen in the last audio
// callback as a fraction of full scale (0.0 to 1.0). It decays toward zero so
// the UI can render a falling level meter.
func (r *Recorder) CurrentPeak() float64 {
	r.peakMu.Lock()
	defer r.peakMu.Unlock()
	current := r.currentPeak
	r.currentPeak *= 0.7
	return current
}

// SessionPeak returns the loudest sample seen since the last Start().
func (r *Recorder) SessionPeak() float64 {
	r.peakMu.Lock()
	defer r.peakMu.Unlock()
	return r.sessionPeak
}

// SessionRMS returns the root-mean-square amplitude (0.0 to 1.0) over the whole
// recording. Unlike the peak, it reflects sustained loudness, which is a good
// proxy for whether speech (vs. background silence) was actually captured.
func (r *Recorder) SessionRMS() float64 {
	r.peakMu.Lock()
	defer r.peakMu.Unlock()
	if r.sampleCount == 0 {
		return 0
	}
	return math.Sqrt(r.sumSquares / float64(r.sampleCount))
}

func (r *Recorder) updatePeak(samples []byte) {
	if len(samples) < 2 {
		return
	}
	var peak int16
	var sumSquares float64
	count := 0
	for i := 0; i+1 < len(samples); i += 2 {
		s := int16(binary.LittleEndian.Uint16(samples[i : i+2]))
		fraction := float64(s) / 32768.0
		sumSquares += fraction * fraction
		count++
		if s < 0 {
			s = -s - 1
		}
		if s > peak {
			peak = s
		}
	}
	fraction := float64(peak) / 32768.0

	r.peakMu.Lock()
	if fraction > r.currentPeak {
		r.currentPeak = fraction
	}
	if fraction > r.sessionPeak {
		r.sessionPeak = fraction
	}
	r.sumSquares += sumSquares
	r.sampleCount += int64(count)
	r.peakMu.Unlock()
}
