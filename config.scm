;;;; config.scm — edit this, then make. Included by yadatty.scm,
;;;; the same way st includes config.h.

;; Initial size in cells. The glyph cell itself is 8×16 and is not
;; configurable: the atlas and the compute shader share that pitch.
(define cols 80)
(define rows 24)

;; Window class and the title used until the shell sets one.
(define window-name "yadatty")
(define window-class "Yadatty")

;; Smallest window, in cells.
(define min-cols 2)
(define min-rows 1)

;; Executed when argv has no command, $SHELL is unset, and passwd has
;; no shell. Command line and -e still win, then $SHELL, then passwd.
(define fallback-shell "/bin/sh")
(define term-name "xterm-256color")
(define colorterm "truecolor")

;; Double-click and triple-click window, in milliseconds.
(define click-timeout-ms 400)

;; Text and cursor blink period. 0 disables blinking.
(define blink-timeout-ms 530)

;; Rows the wheel scrolls. 0 passes the wheel to the application.
(define wheel-scroll 3)

;; Held to select while an application is tracking the mouse, and held
;; to make a selection rectangular.
(define select-modifier mod-shift)
(define rect-modifier mod-alt)

;; Keyboard bindings. Each entry is (mods key action).
;; mods is a mask of mod-shift, mod-ctrl, mod-alt, and mod-super.
;; The binding matches when exactly those are held. Use any to ignore
;; modifiers. key-letter and key-digit take a character. Actions:
;;   copy-clipboard paste-clipboard paste-primary
;;   scroll-page-up scroll-page-down scroll-top scroll-bottom
(define shortcuts
  `((,(bitwise-ior mod-ctrl mod-shift) ,(key-letter #\c) copy-clipboard)
    (,(bitwise-ior mod-ctrl mod-shift) ,(key-letter #\v) paste-clipboard)
    (,mod-shift ,key-insert paste-primary)
    (,mod-shift ,key-page-up scroll-page-up)
    (,mod-shift ,key-page-down scroll-page-down)
    (,mod-shift ,key-home scroll-top)
    (,mod-shift ,key-end scroll-bottom)))

;; Mouse bindings, on press. Each entry is (mods button action).
;; Buttons are X numbers: 1 left, 2 middle, 3 right, 4 wheel up, 5 wheel down.
;; scroll-up and scroll-down also run when the application is not
;; tracking the mouse. paste-primary does not, so a full-screen program
;; can still see the button.
(define mouse-shortcuts
  `((,mod-shift 4 scroll-up)
    (,mod-shift 5 scroll-down)
    (any 2 paste-primary)))
