//go:build darwin && cgo

package hotkey

/*
#cgo darwin LDFLAGS: -framework ApplicationServices -framework CoreFoundation
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>

extern void handleMacHotkeyEvent(long long keycode, int eventType, unsigned long long flags);
extern void handleMacHotkeyTapStarted(int ok);

static CFMachPortRef voicyEventTap = NULL;
static CFRunLoopRef voicyRunLoop = NULL;

static CGEventRef voicyEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
	if (type == kCGEventKeyDown || type == kCGEventKeyUp || type == kCGEventFlagsChanged) {
		long long keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
		unsigned long long flags = (unsigned long long)CGEventGetFlags(event);
		handleMacHotkeyEvent(keycode, (int)type, flags);
	}
	return event;
}

static int voicyStartEventTap(void) {
	CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventFlagsChanged);
	voicyEventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, mask, voicyEventCallback, NULL);
	if (voicyEventTap == NULL) {
		handleMacHotkeyTapStarted(0);
		return 0;
	}

	CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, voicyEventTap, 0);
	voicyRunLoop = CFRunLoopGetCurrent();
	CFRunLoopAddSource(voicyRunLoop, source, kCFRunLoopCommonModes);
	CFRelease(source);

	CGEventTapEnable(voicyEventTap, true);
	handleMacHotkeyTapStarted(1);
	CFRunLoopRun();

	if (voicyEventTap != NULL) {
		CFMachPortInvalidate(voicyEventTap);
		CFRelease(voicyEventTap);
		voicyEventTap = NULL;
	}
	voicyRunLoop = NULL;
	return 1;
}

static void voicyStopEventTap(void) {
	if (voicyEventTap != NULL) {
		CGEventTapEnable(voicyEventTap, false);
	}
	if (voicyRunLoop != NULL) {
		CFRunLoopStop(voicyRunLoop);
	}
}
*/
import "C"

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/janis/voicy/internal/app"
)

const (
	macFlagCapsLock    = 1 << 16
	macFlagShift       = 1 << 17
	macFlagControl     = 1 << 18
	macFlagOption      = 1 << 19
	macFlagSecondaryFn = 1 << 23
)

type Service struct {
	key       string
	keyMu     sync.RWMutex
	callbacks app.HotkeyCallbacks
	cancel    context.CancelFunc
	done      chan struct{}
	started   chan error
	pressed   atomic.Bool
}

var (
	activeMu      sync.Mutex
	activeService *Service
)

func NewService(key string) *Service {
	if key == "" {
		key = "right_option"
	}
	return &Service{key: normalizeKey(key)}
}

func (s *Service) SetKey(key string) {
	if key == "" {
		key = "right_option"
	}
	s.keyMu.Lock()
	defer s.keyMu.Unlock()
	s.key = normalizeKey(key)
}

func (s *Service) Start(ctx context.Context, callbacks app.HotkeyCallbacks) error {
	activeMu.Lock()
	if activeService != nil {
		activeMu.Unlock()
		return errors.New("hotkey service is already running")
	}
	runCtx, cancel := context.WithCancel(ctx)
	s.callbacks = callbacks
	s.cancel = cancel
	s.done = make(chan struct{})
	s.started = make(chan error, 1)
	activeService = s
	activeMu.Unlock()

	go func() {
		defer close(s.done)
		defer func() {
			activeMu.Lock()
			if activeService == s {
				activeService = nil
			}
			activeMu.Unlock()
		}()

		go func() {
			<-runCtx.Done()
			C.voicyStopEventTap()
		}()

		C.voicyStartEventTap()
	}()

	select {
	case err := <-s.started:
		return err
	case <-time.After(2 * time.Second):
		return nil
	}
}

func (s *Service) Stop() error {
	if s.cancel != nil {
		s.cancel()
	}
	C.voicyStopEventTap()
	if s.done != nil {
		<-s.done
	}
	return nil
}

//export handleMacHotkeyTapStarted
func handleMacHotkeyTapStarted(ok C.int) {
	activeMu.Lock()
	s := activeService
	activeMu.Unlock()
	if s == nil || s.started == nil {
		return
	}

	var err error
	if ok == 0 {
		err = errors.New("macOS event tap could not be created; grant Accessibility permission and restart Voicy")
	}
	select {
	case s.started <- err:
	default:
	}
}

//export handleMacHotkeyEvent
func handleMacHotkeyEvent(keycode C.longlong, eventType C.int, flags C.ulonglong) {
	activeMu.Lock()
	s := activeService
	activeMu.Unlock()
	if s == nil {
		return
	}

	pressed, ok := s.eventMatches(int64(keycode), int(eventType), uint64(flags))
	if !ok {
		return
	}

	if pressed {
		if s.pressed.CompareAndSwap(false, true) && s.callbacks.OnPress != nil {
			go s.callbacks.OnPress()
		}
		return
	}

	if s.pressed.CompareAndSwap(true, false) && s.callbacks.OnRelease != nil {
		go s.callbacks.OnRelease()
	}
}

func (s *Service) eventMatches(keycode int64, eventType int, flags uint64) (bool, bool) {
	s.keyMu.RLock()
	key := s.key
	s.keyMu.RUnlock()

	if key == "fn" {
		if eventType == int(C.kCGEventFlagsChanged) {
			return flags&macFlagSecondaryFn != 0, true
		}
		if keycode == 63 {
			return eventType == int(C.kCGEventKeyDown), true
		}
		return false, false
	}

	modifier, isModifier := macModifierKeys[key]
	if isModifier {
		if eventType != int(C.kCGEventFlagsChanged) || keycode != modifier.keycode {
			return false, false
		}
		return flags&modifier.flag != 0, true
	}

	expected, ok := macRegularKeycodes[key]
	if !ok || keycode != expected {
		return false, false
	}
	switch eventType {
	case int(C.kCGEventKeyDown):
		return true, true
	case int(C.kCGEventKeyUp):
		return false, true
	default:
		return false, false
	}
}

func normalizeKey(key string) string {
	return strings.ToLower(strings.TrimSpace(strings.ReplaceAll(key, " ", "_")))
}

type macModifierKey struct {
	keycode int64
	flag    uint64
}

var macRegularKeycodes = map[string]int64{
	"space": 49,
}

var macModifierKeys = map[string]macModifierKey{
	"caps_lock":     {keycode: 57, flag: macFlagCapsLock},
	"left_control":  {keycode: 59, flag: macFlagControl},
	"right_control": {keycode: 62, flag: macFlagControl},
	"left_option":   {keycode: 58, flag: macFlagOption},
	"right_option":  {keycode: 61, flag: macFlagOption},
	"left_shift":    {keycode: 56, flag: macFlagShift},
	"right_shift":   {keycode: 60, flag: macFlagShift},
}
