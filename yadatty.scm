;;;; yadatty — a libghostty-vt terminal in Chicken Scheme.
;;;; OpenGL ES 3.1 compute shader, X11 + EGL. No eggs.
;;;; yadatty-native.c is included into this translation unit.
;;;; config.scm is the part you edit.

(import scheme
        (chicken base)
        (chicken bitwise)
        (chicken foreign)
        (chicken process-context)
        srfi-4)

(foreign-declare "#include \"yadatty-native.c\"")


(define y-init (foreign-lambda* int () "C_return(y_init());"))
(define y-spawn (foreign-lambda* int () "C_return(y_spawn());"))
(define y-map (foreign-lambda* void () "y_map();"))
(define y-swap (foreign-lambda* void () "y_swap();"))
(define y-shutdown (foreign-lambda* void () "y_shutdown();"))
(define y-xpending (foreign-lambda* int () "C_return(y_xpending());"))
(define y-next-event (foreign-lambda* int ((s32vector out)) "C_return(y_next_event(out));"))
(define y-drain (foreign-lambda* int () "C_return(y_drain());"))
(define y-wait (foreign-lambda* int ((int timeout)) "C_return(y_wait(timeout));"))
(define y-alive (foreign-lambda* int () "C_return(y_alive());"))
(define y-cols (foreign-lambda* int () "C_return(y_cols());"))
(define y-rows (foreign-lambda* int () "C_return(y_rows());"))
(define y-width (foreign-lambda* int () "C_return(y_width());"))
(define y-height (foreign-lambda* int () "C_return(y_height());"))
(define y-pad-x (foreign-lambda* int () "C_return(y_pad_x());"))
(define y-pad-y (foreign-lambda* int () "C_return(y_pad_y());"))
(define y-resize (foreign-lambda* void ((int w) (int h)) "y_resize(w, h);"))
(define y-pty-write (foreign-lambda* void ((u8vector data) (int len)) "y_pty_write(data, len);"))
(define y-copy-key-utf (foreign-lambda* void ((u8vector dst) (int n)) "y_copy_key_utf(dst, n);"))
(define y-key-encode
  (foreign-lambda* int ((int action) (int key) (int mods) (int unshifted) (u8vector utf) (int n))
    "C_return(y_key_encode(action, key, mods, unshifted, utf, n));"))
(define y-mouse-tracking (foreign-lambda* int () "C_return(y_mouse_tracking());"))
(define y-focus-reporting (foreign-lambda* int () "C_return(y_focus_reporting());"))
(define y-focus-write (foreign-lambda* void ((int in)) "y_focus_write(in);"))
(define y-scroll-delta (foreign-lambda* void ((int delta)) "y_scroll_delta(delta);"))
(define y-scroll-edge (foreign-lambda* void ((int top)) "y_scroll_edge(top);"))
(define y-select-cells
  (foreign-lambda* void ((int c0) (int r0) (int c1) (int r1) (int rect))
    "y_select_cells(c0, r0, c1, r1, rect);"))
(define y-select-word (foreign-lambda* void ((int c) (int r)) "y_select_word(c, r);"))
(define y-select-line (foreign-lambda* void ((int c) (int r)) "y_select_line(c, r);"))
(define y-clear-selection (foreign-lambda* void () "y_clear_selection();"))
(define y-copy-selection (foreign-lambda* int ((u8vector dst) (int cap)) "C_return(y_copy_selection(dst, cap));"))
(define y-own (foreign-lambda* void ((int clipboard) (u8vector data) (int len)) "y_own(clipboard, data, len);"))
(define y-request-paste (foreign-lambda* void ((int clipboard)) "y_request_paste(clipboard);"))
(define y-take-paste (foreign-lambda* int ((u8vector dst) (int cap)) "C_return(y_take_paste(dst, cap));"))
(define y-apply-paste
  (foreign-lambda* void ((u8vector data) (int len) (int clipboard)) "y_apply_paste(data, len, clipboard);"))
(define y-grab (foreign-lambda* void () "y_grab();"))
(define y-ungrab (foreign-lambda* void () "y_ungrab();"))
(define y-mouse-button
  (foreign-lambda* void ((int press) (int button) (int mods) (int x) (int y) (int any))
    "y_mouse_button(press, button, mods, x, y, any);"))
(define y-mouse-motion
  (foreign-lambda* void ((int mods) (int x) (int y) (int mask))
    "y_mouse_motion(mods, x, y, mask);"))
(define y-mouse-wheel
  (foreign-lambda* void ((int button) (int mods) (int x) (int y) (int any))
    "y_mouse_wheel(button, mods, x, y, any);"))
(define y-title (foreign-lambda* void () "y_title();"))
(define y-now-ns (foreign-lambda* double () "C_return(y_now_ns());"))
(define y-blink-phase (foreign-lambda* int ((int enabled)) "C_return(y_blink_phase(enabled));"))
(define y-blink-timeout (foreign-lambda* int ((int enabled)) "C_return(y_blink_timeout(enabled));"))
(define y-render-sync (foreign-lambda* int ((s32vector info)) "C_return(y_render_sync(info));"))
(define y-clear-dirty (foreign-lambda* void () "y_clear_dirty();"))
(define y-rows-open (foreign-lambda* int () "C_return(y_rows_open());"))
(define y-iter-next (foreign-lambda* int () "C_return(y_iter_next());"))
(define y-iter-dirty (foreign-lambda* int () "C_return(y_iter_dirty());"))
(define y-iter-cells (foreign-lambda* int ((s32vector sel)) "C_return(y_iter_cells(sel));"))
(define y-cell (foreign-lambda* int ((s32vector info)) "C_return(y_cell(info));"))
(define y-upload-atlas (foreign-lambda* void ((u8vector px) (int w) (int h)) "y_upload_atlas(px, w, h);"))
(define y-upload-cells (foreign-lambda* void ((u32vector cells) (int n)) "y_upload_cells(cells, n);"))
(define y-gl-clear
  (foreign-lambda* void ((int w) (int h) (int r) (int g) (int b)) "y_gl_clear(w, h, r, g, b);"))
(define y-gl-compute
  (foreign-lambda* void ((int cols) (int rows) (int on) (int r) (int g) (int b) (int explicit))
    "y_gl_compute(cols, rows, on, r, g, b, explicit);"))
(define y-gl-present
  (foreign-lambda* void ((int pad) (int bottom) (int gw) (int gh)) "y_gl_present(pad, bottom, gw, gh);"))
(define y-configure
  (foreign-lambda* void ((int c) (int r) (int minc) (int minr) (int blink)
                         (c-string name) (c-string cls) (c-string term)
                         (c-string cterm) (c-string shell))
    "y_configure(c, r, minc, minr, blink, name, cls, term, cterm, shell);"))

(define cell-w 8)
(define cell-h 16)
(define atlas-cols 16)
(define pad-x 0)
(define pad-y 0)
(define cells #f)
(define atlas-px #f)
(define atlas-w 0)
(define atlas-h 0)
(define glyph-table (make-vector 256 '()))
(define glyph-list '())

(define alive? #t)
(define dirty? #t)
(define text-blink? #f)
(define cursor-blinks? #f)
(define cursor-phase? #t)
(define focused? #f)
(define selecting? #f)
(define select-armed? #f)
(define select-rect? #f)
(define click-count 1)
(define anchor-col 0)
(define anchor-row 0)
(define last-click-ns 0.0)
(define last-click-col 0)
(define last-click-row 0)
(define button-mask 0)
(define paste-clip? #t)

(define ev (make-s32vector 16 0))
(define info (make-s32vector 24 0))
(define cellv (make-s32vector 16 0))
(define selv (make-s32vector 4 0))
(define text-buf (make-u8vector 1048576 0))
(define key-bytes (make-u8vector 64 0))

(define flag-bold 1)
(define flag-italic 2)
(define flag-faint 4)
(define flag-blink 8)
(define flag-inverse 16)
(define flag-invisible 32)
(define flag-strike 64)
(define flag-overline 128)
(define attr-under 1)
(define attr-strike 2)
(define attr-over 4)
(define attr-bold 8)
(define attr-italic 16)
(define attr-cursor 32)
(define attr-bar 64)
(define attr-cursor-under 128)
(define attr-hollow 256)
(define cursor-bar 0)
(define cursor-underline 2)
(define cursor-hollow 3)

(define key-space 63)
(define key-enter 58)
(define key-tab 64)
(define key-escape 120)
(define key-backspace 53)
(define key-delete 68)
(define key-insert 72)
(define key-home 71)
(define key-end 69)
(define key-page-up 74)
(define key-page-down 73)
(define key-up 78)
(define key-down 75)
(define key-left 76)
(define key-right 77)
(define key-f1 121)
(define key-a 20)
(define (key-letter ch)
  (+ key-a (- (char->integer (char-downcase ch)) (char->integer #\a))))
(define (key-digit ch)
  (+ 6 (- (char->integer ch) (char->integer #\0))))
(define (key-fn n) (+ key-f1 (- n 1)))
(define mod-shift 1)
(define mod-ctrl 2)
(define mod-alt 4)
(define mod-super 8)
(define action-release 0)
(define action-press 1)
(define action-repeat 2)

(include "config.scm")

(define width (* cols cell-w))
(define height (* rows cell-h))

(define ascii-font #u8(
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  0 0 0 0 0 0 0 0 24 60 60 24 24 0 24 0
  54 54 0 0 0 0 0 0 54 54 127 54 127 54 54 0
  12 62 3 30 48 31 12 0 0 99 51 24 12 102 99 0
  28 54 28 110 59 51 110 0 6 6 3 0 0 0 0 0
  24 12 6 6 6 12 24 0 6 12 24 24 24 12 6 0
  0 102 60 255 60 102 0 0 0 12 12 63 12 12 0 0
  0 0 0 0 0 12 12 6 0 0 0 63 0 0 0 0
  0 0 0 0 0 12 12 0 96 48 24 12 6 3 1 0
  62 99 115 123 111 103 62 0 12 14 12 12 12 12 63 0
  30 51 48 28 6 51 63 0 30 51 48 28 48 51 30 0
  56 60 54 51 127 48 120 0 63 3 31 48 48 51 30 0
  28 6 3 31 51 51 30 0 63 51 48 24 12 12 12 0
  30 51 51 30 51 51 30 0 30 51 51 62 48 24 14 0
  0 12 12 0 0 12 12 0 0 12 12 0 0 12 12 6
  24 12 6 3 6 12 24 0 0 0 63 0 0 63 0 0
  6 12 24 48 24 12 6 0 30 51 48 24 12 0 12 0
  62 99 123 123 123 3 30 0 12 30 51 51 63 51 51 0
  63 102 102 62 102 102 63 0 60 102 3 3 3 102 60 0
  31 54 102 102 102 54 31 0 127 70 22 30 22 70 127 0
  127 70 22 30 22 6 15 0 60 102 3 3 115 102 124 0
  51 51 51 63 51 51 51 0 30 12 12 12 12 12 30 0
  120 48 48 48 51 51 30 0 103 102 54 30 54 102 103 0
  15 6 6 6 70 102 127 0 99 119 127 127 107 99 99 0
  99 103 111 123 115 99 99 0 28 54 99 99 99 54 28 0
  63 102 102 62 6 6 15 0 30 51 51 51 59 30 56 0
  63 102 102 62 54 102 103 0 30 51 7 14 56 51 30 0
  63 45 12 12 12 12 30 0 51 51 51 51 51 51 63 0
  51 51 51 51 51 30 12 0 99 99 99 107 127 119 99 0
  99 99 54 28 28 54 99 0 51 51 51 30 12 12 30 0
  127 99 49 24 76 102 127 0 30 6 6 6 6 6 30 0
  3 6 12 24 48 96 64 0 30 24 24 24 24 24 30 0
  8 28 54 99 0 0 0 0 0 0 0 0 0 0 0 255
  12 12 24 0 0 0 0 0 0 0 30 48 62 51 110 0
  7 6 6 62 102 102 59 0 0 0 30 51 3 51 30 0
  56 48 48 62 51 51 110 0 0 0 30 51 63 3 30 0
  28 54 6 15 6 6 15 0 0 0 110 51 51 62 48 31
  7 6 54 110 102 102 103 0 12 0 14 12 12 12 30 0
  48 0 48 48 48 51 51 30 7 6 102 54 30 54 103 0
  14 12 12 12 12 12 30 0 0 0 51 127 127 107 99 0
  0 0 31 51 51 51 51 0 0 0 30 51 51 51 30 0
  0 0 59 102 102 62 6 15 0 0 110 51 51 62 48 120
  0 0 59 110 102 6 15 0 0 0 62 3 30 48 31 0
  8 12 62 12 12 44 24 0 0 0 51 51 51 51 110 0
  0 0 51 51 51 30 12 0 0 0 99 107 127 127 54 0
  0 0 99 54 28 54 99 0 0 0 51 51 51 62 48 31
  0 0 63 25 12 38 63 0 56 12 12 7 12 12 56 0
  24 24 24 0 24 24 24 0 7 12 12 56 12 12 7 0
  110 59 0 0 0 0 0 0 0 0 0 0 0 0 0 0))

(define (has? bits mask) (not (zero? (bitwise-and bits mask))))

(define (glyph-new) (make-u8vector (* cell-w cell-h) 0))

(define (glyph-set! g x y)
  (when (and (>= x 0) (< x cell-w) (>= y 0) (< y cell-h))
    (u8vector-set! g (+ (* y cell-w) x) 255)))

(define (from-ascii cp)
  (let ((g (glyph-new)))
    (do ((y 0 (+ y 1))) ((= y 8) g)
      (let ((bits (u8vector-ref ascii-font (+ (* cp 8) y))))
        (do ((x 0 (+ x 1))) ((= x 8))
          (when (has? bits (arithmetic-shift 1 x))
            (glyph-set! g x (* y 2))
            (glyph-set! g x (+ (* y 2) 1))))))))

(define (hbar! g y x0 x1 thick)
  (do ((t 0 (+ t 1))) ((= t thick))
    (do ((x x0 (+ x 1))) ((> x x1))
      (glyph-set! g x (+ y t)))))

(define (vbar! g x y0 y1 thick)
  (do ((t 0 (+ t 1))) ((= t thick))
    (do ((y y0 (+ y 1))) ((> y y1))
      (glyph-set! g (+ x t) y))))

(define (draw-box! g mask style)
  (cond
   ((= style 3)
    (when (has? mask 1) (hbar! g 6 0 3 1) (hbar! g 9 0 3 1))
    (when (has? mask 2) (hbar! g 6 4 7 1) (hbar! g 9 4 7 1))
    (when (has? mask 4) (vbar! g 2 0 6 1) (vbar! g 5 0 6 1))
    (when (has? mask 8) (vbar! g 2 9 15 1) (vbar! g 5 9 15 1)))
   (else
    (let ((t (if (= style 2) 2 1))
          (cx 3)
          (cy 7))
      (when (has? mask 1) (hbar! g cy 0 cx t))
      (when (has? mask 2) (hbar! g cy cx 7 t))
      (when (has? mask 4) (vbar! g cx 0 (+ cy t -1) t))
      (when (has? mask 8) (vbar! g cx cy 15 t))))))

(define (fill-rect! g x0 y0 x1 y1)
  (do ((y y0 (+ y 1))) ((> y y1))
    (do ((x x0 (+ x 1))) ((> x x1))
      (glyph-set! g x y))))

(define (atlas-add! cp g)
  (let ((id (+ (length glyph-list) 1))
        (i (modulo cp 256)))
    (vector-set! glyph-table i (cons (cons cp id) (vector-ref glyph-table i)))
    (set! glyph-list (cons g glyph-list))))

(define (blit! px stride id g)
  (let ((col (modulo id atlas-cols))
        (row (quotient id atlas-cols)))
    (let ((ox (* col cell-w))
          (oy (* row cell-h)))
      (do ((y 0 (+ y 1))) ((= y cell-h))
        (do ((x 0 (+ x 1))) ((= x cell-w))
          (u8vector-set! px (+ (* (+ oy y) stride) ox x)
                         (u8vector-ref g (+ (* y cell-w) x))))))))

(define (atlas-finish!)
  (let* ((gs (reverse glyph-list))
         (count (+ (length gs) 1))
         (nrows (quotient (+ count atlas-cols -1) atlas-cols))
         (w (* atlas-cols cell-w))
         (h (* nrows cell-h))
         (px (make-u8vector (* w h) 0)))
    (let loop ((i 0) (rest gs))
      (if (null? rest)
          (begin (set! atlas-px px) (set! atlas-w w) (set! atlas-h h))
          (begin (blit! px w (+ i 1) (car rest)) (loop (+ i 1) (cdr rest)))))))

(define (add-block! cp x0 y0 x1 y1)
  (let ((g (glyph-new)))
    (fill-rect! g x0 y0 x1 y1)
    (atlas-add! cp g)))

(define (add-shade! cp num den)
  (let ((g (glyph-new))
        (i 0))
    (do ((y 0 (+ y 1))) ((= y cell-h))
      (do ((x 0 (+ x 1))) ((= x cell-w))
        (when (< (modulo i den) num) (glyph-set! g x y))
        (set! i (+ i 1))))
    (atlas-add! cp g)))

(define box-specs
  '((#x2500 3 1) (#x2501 3 2) (#x2502 12 1) (#x2503 12 2)
    (#x250c 10 1) (#x2510 6 1) (#x2514 5 1) (#x2518 9 1)
    (#x251c 13 1) (#x2524 14 1) (#x252c 7 1) (#x2534 11 1) (#x253c 15 1)
    (#x2550 3 3) (#x2551 12 3) (#x2554 10 3) (#x2557 6 3)
    (#x255a 5 3) (#x255d 9 3) (#x2560 13 3) (#x2563 14 3)
    (#x2566 7 3) (#x2569 11 3) (#x256c 15 3)))

(define (make-atlas!)
  (let ((missing (glyph-new)))
    (do ((x 1 (+ x 1))) ((> x 6))
      (glyph-set! missing x 2)
      (glyph-set! missing x 13))
    (do ((y 2 (+ y 1))) ((> y 13))
      (glyph-set! missing 1 y)
      (glyph-set! missing 6 y))
    (atlas-add! #xfffd missing))
  (do ((cp #x20 (+ cp 1))) ((> cp #x7e))
    (atlas-add! cp (from-ascii cp)))
  (for-each
   (lambda (spec)
     (let ((g (glyph-new)))
       (draw-box! g (cadr spec) (caddr spec))
       (atlas-add! (car spec) g)))
   box-specs)
  (add-block! #x2580 0 0 7 7)
  (add-block! #x2581 0 14 7 15)
  (add-block! #x2582 0 12 7 15)
  (add-block! #x2583 0 10 7 15)
  (add-block! #x2584 0 8 7 15)
  (add-block! #x2585 0 6 7 15)
  (add-block! #x2586 0 4 7 15)
  (add-block! #x2587 0 2 7 15)
  (add-block! #x2588 0 0 7 15)
  (add-block! #x258c 0 0 3 15)
  (add-block! #x2590 4 0 7 15)
  (add-shade! #x2591 1 4)
  (add-shade! #x2592 1 2)
  (add-shade! #x2593 3 4)
  (atlas-finish!))

(define (glyph-of cp)
  (let loop ((bucket (vector-ref glyph-table (modulo cp 256))))
    (cond ((null? bucket) 1)
          ((eqv? (caar bucket) cp) (cdar bucket))
          (else (loop (cdr bucket))))))

(define (pack r g b)
  (bitwise-ior (bitwise-and r 255)
               (arithmetic-shift (bitwise-and g 255) 8)
               (arithmetic-shift (bitwise-and b 255) 16)
               (arithmetic-shift 255 24)))

(define (sync-geom)
  (set! cols (y-cols))
  (set! rows (y-rows))
  (set! width (y-width))
  (set! height (y-height))
  (set! pad-x (y-pad-x))
  (set! pad-y (y-pad-y)))

(define (ensure-cells)
  (let ((n (* cols rows 4)))
    (unless (and cells (= (u32vector-length cells) n))
      (set! cells (make-u32vector n 0)))))

(define (store-cell x y)
  (let* ((wide (s32vector-ref cellv 0))
         (cp (s32vector-ref cellv 1))
         (flags (s32vector-ref cellv 2))
         (underline (s32vector-ref cellv 3))
         (fg-set (s32vector-ref cellv 4))
         (bg-set (s32vector-ref cellv 8))
         (spacer (or (= wide 2) (= wide 3)))
         (fg-r (if (= fg-set 1) (s32vector-ref cellv 5) (s32vector-ref info 4)))
         (fg-g (if (= fg-set 1) (s32vector-ref cellv 6) (s32vector-ref info 5)))
         (fg-b (if (= fg-set 1) (s32vector-ref cellv 7) (s32vector-ref info 6)))
         (bg-r (if (= bg-set 1) (s32vector-ref cellv 9) (s32vector-ref info 1)))
         (bg-g (if (= bg-set 1) (s32vector-ref cellv 10) (s32vector-ref info 2)))
         (bg-b (if (= bg-set 1) (s32vector-ref cellv 11) (s32vector-ref info 3))))
    (when (has? flags flag-inverse)
      (let ((tr fg-r) (tg fg-g) (tb fg-b))
        (set! fg-r bg-r) (set! fg-g bg-g) (set! fg-b bg-b)
        (set! bg-r tr) (set! bg-g tg) (set! bg-b tb)))
    (when (and (= (s32vector-ref selv 0) 1)
               (>= x (s32vector-ref selv 1))
               (<= x (s32vector-ref selv 2)))
      (let ((tr fg-r) (tg fg-g) (tb fg-b))
        (set! fg-r bg-r) (set! fg-g bg-g) (set! fg-b bg-b)
        (set! bg-r tr) (set! bg-g tg) (set! bg-b tb)))
    (when (has? flags flag-faint)
      (set! fg-r (quotient (* fg-r 2) 3))
      (set! fg-g (quotient (* fg-g 2) 3))
      (set! fg-b (quotient (* fg-b 2) 3)))
    (let ((attr 0))
      (when (has? flags flag-bold) (set! attr (bitwise-ior attr attr-bold)))
      (when (has? flags flag-italic) (set! attr (bitwise-ior attr attr-italic)))
      (unless (zero? underline) (set! attr (bitwise-ior attr attr-under)))
      (when (has? flags flag-strike) (set! attr (bitwise-ior attr attr-strike)))
      (when (has? flags flag-overline) (set! attr (bitwise-ior attr attr-over)))
      (when (has? flags flag-blink) (set! text-blink? #t))
      (let* ((hide (or (has? flags flag-invisible)
                       (and (has? flags flag-blink) (not cursor-phase?))))
             (glyph (if (or hide spacer (zero? cp)) 0 (glyph-of cp)))
             (base (* 4 (+ x (* y cols)))))
        (when (and (= (s32vector-ref info 11) 1)
                   (= (s32vector-ref info 14) 1)
                   (= (s32vector-ref info 12) x)
                   (= (s32vector-ref info 13) y))
          (set! attr (bitwise-ior attr attr-cursor))
          (let ((style (s32vector-ref info 16)))
            (cond ((= style cursor-bar) (set! attr (bitwise-ior attr attr-bar)))
                  ((= style cursor-underline) (set! attr (bitwise-ior attr attr-cursor-under)))
                  ((= style cursor-hollow) (set! attr (bitwise-ior attr attr-hollow))))))
        (u32vector-set! cells base glyph)
        (u32vector-set! cells (+ base 1) (pack fg-r fg-g fg-b))
        (u32vector-set! cells (+ base 2) (pack bg-r bg-g bg-b))
        (u32vector-set! cells (+ base 3) attr)))))

(define (fill-row y)
  (when (and (< y rows) (= (y-iter-cells selv) 1))
    (let loop ((x 0))
      (when (and (< x cols) (= (y-cell cellv) 1))
        (store-cell x y)
        (loop (+ x 1))))))

(define (rebuild every?)
  (when (= (y-rows-open) 1)
    (set! text-blink? #f)
    (if every?
        (let loop ((y 0))
          (when (= (y-iter-next) 1)
            (fill-row y)
            (loop (+ y 1))))
        (let loop ()
          (let ((y (y-iter-dirty)))
            (when (>= y 0)
              (fill-row y)
              (loop)))))))

(define (draw)
  (when (= (y-render-sync info) 1)
    (let* ((dirty (s32vector-ref info 0))
           (refresh text-blink?)
           (every? (or refresh (= dirty 2))))
      (when (or (not (zero? dirty)) refresh) (rebuild every?))
      (y-clear-dirty)
      (y-gl-clear width height (s32vector-ref info 1) (s32vector-ref info 2) (s32vector-ref info 3))
      (y-upload-cells cells (* cols rows))
      (let* ((blinking (= (s32vector-ref info 15) 1))
             (visible (= (s32vector-ref info 14) 1))
             (show (and visible (or (not blinking) cursor-phase?)))
             (has (= (s32vector-ref info 7) 1)))
        (y-gl-compute cols rows (if show 1 0)
                      (if has (s32vector-ref info 8) 0)
                      (if has (s32vector-ref info 9) 0)
                      (if has (s32vector-ref info 10) 0)
                      (if has 1 0))
        (y-gl-present pad-x (- height pad-y (* rows cell-h)) (* cols cell-w) (* rows cell-h))
        (set! cursor-blinks? blinking)))))

(define (blink-on?)
  (not (zero? (y-blink-phase (if (or text-blink? cursor-blinks?) 1 0)))))

(define (cell-at x y)
  (let ((lx (- x pad-x))
        (ly (- y pad-y)))
    (if (or (< lx 0) (< ly 0))
        #f
        (let ((c (quotient lx cell-w))
              (r (quotient ly cell-h)))
          (if (or (>= c cols) (>= r rows)) #f (cons c r))))))

(define (copy-selection! clipboard?)
  (let ((n (y-copy-selection text-buf (u8vector-length text-buf))))
    (when (>= n 0) (y-own (if clipboard? 1 0) text-buf n))))

(define (request-paste! clipboard?)
  (set! paste-clip? clipboard?)
  (y-request-paste (if clipboard? 1 0)))

(define (apply-paste! clipboard?)
  (let ((n (y-take-paste text-buf (u8vector-length text-buf))))
    (when (> n 0)
      (y-apply-paste text-buf n (if clipboard? 1 0))
      (set! dirty? #t))))

(define (begin-select col row mods)
  (let ((t (y-now-ns)))
    (if (and (< (- t last-click-ns) (* click-timeout-ms 1000000.0))
             (= col last-click-col)
             (= row last-click-row))
        (set! click-count (if (>= click-count 3) 1 (+ click-count 1)))
        (set! click-count 1))
    (set! last-click-ns t)
    (set! last-click-col col)
    (set! last-click-row row)
    (set! anchor-col col)
    (set! anchor-row row)
    (set! select-rect? (has? mods rect-modifier))
    (set! selecting? (= click-count 1))
    (set! select-armed? #t)
    (cond ((= click-count 2) (y-select-word col row))
          ((= click-count 3) (y-select-line col row))
          (else (y-select-cells col row col row (if select-rect? 1 0))))
    (set! dirty? #t)
    (y-grab)))

(define (button-map b)
  (cond ((= b 1) (cons 1 1))
        ((= b 2) (cons 3 2))
        ((= b 3) (cons 2 4))
        ((= b 8) (cons 8 8))
        ((= b 9) (cons 9 16))
        (else (cons 0 0))))

(define mod-mask (bitwise-ior mod-shift (bitwise-ior mod-ctrl (bitwise-ior mod-alt mod-super))))

(define (mods-match? want got)
  (or (eq? want 'any) (= (bitwise-and got mod-mask) want)))

(define (lookup-binding xs button-or-key mods)
  (let loop ((rest xs))
    (if (null? rest)
        #f
        (let ((b (car rest)))
          (if (and (mods-match? (car b) mods) (= (cadr b) button-or-key))
              (caddr b)
              (loop (cdr rest)))))))

(define (scroll-action? action)
  (or (eq? action 'scroll-up) (eq? action 'scroll-down)))

(define (any-scroll button)
  (let loop ((rest mouse-shortcuts))
    (if (null? rest)
        #f
        (let ((b (car rest)))
          (if (and (= (cadr b) button) (scroll-action? (caddr b)))
              (caddr b)
              (loop (cdr rest)))))))

(define (page-rows)
  (let ((n (- rows 1))) (if (< n 1) 1 n)))

(define (run-key-shortcut action)
  (case action
    ((copy-clipboard) (copy-selection! #t) #t)
    ((paste-clipboard) (request-paste! #t) #t)
    ((paste-primary) (request-paste! #f) #t)
    ((scroll-page-up) (y-scroll-delta (- (page-rows))) (set! dirty? #t) #t)
    ((scroll-page-down) (y-scroll-delta (page-rows)) (set! dirty? #t) #t)
    ((scroll-top) (y-scroll-edge 1) (set! dirty? #t) #t)
    ((scroll-bottom) (y-scroll-edge 0) (set! dirty? #t) #t)
    (else #f)))

(define (do-wheel-scroll action)
  (unless (zero? wheel-scroll)
    (y-scroll-delta (if (eq? action 'scroll-up) (- wheel-scroll) wheel-scroll))
    (set! dirty? #t)))

(define (on-button)
  (let ((press? (= (s32vector-ref ev 1) 1))
        (button (s32vector-ref ev 2))
        (x (s32vector-ref ev 3))
        (y (s32vector-ref ev 4))
        (mods (s32vector-ref ev 5)))
    (if (or (= button 4) (= button 5))
        (when press?
          (let ((hit (lookup-binding mouse-shortcuts button mods)))
            (cond ((scroll-action? hit) (do-wheel-scroll hit))
                  ((and (zero? (y-mouse-tracking)) (scroll-action? (any-scroll button)))
                   (do-wheel-scroll (any-scroll button)))
                  (else (y-mouse-wheel (if (= button 4) 4 5) mods x y button-mask)))))
        (let* ((mapped (button-map button))
               (gbutton (car mapped))
               (bit (cdr mapped))
               (cell (cell-at x y)))
          (if press?
              (set! button-mask (bitwise-ior button-mask bit))
              (set! button-mask (bitwise-and button-mask (bitwise-not bit))))
          (cond
           ((and (= gbutton 1) press? cell
                 (or (has? mods select-modifier) (zero? (y-mouse-tracking))))
            (begin-select (car cell) (cdr cell) mods))
           ((and (= gbutton 1) (not press?) select-armed?)
            (set! selecting? #f)
            (set! select-armed? #f)
            (y-ungrab)
            (copy-selection! #f))
           ((and press? (eq? (lookup-binding mouse-shortcuts button mods) 'paste-primary)
                 (zero? (y-mouse-tracking)))
            (request-paste! #f))
           ((zero? gbutton) #f)
           (else (y-mouse-button (if press? 1 0) gbutton mods x y button-mask)))))))

(define (encode-key release repeat key mods unshifted utf-n)
  (let ((action (cond ((not (zero? release)) action-release)
                      ((not (zero? repeat)) action-repeat)
                      (else action-press)))
        (n (if (> utf-n 0) utf-n 0)))
    (when (> n 0) (y-copy-key-utf key-bytes n))
    (when (and (zero? (y-key-encode action key mods unshifted key-bytes n))
               (zero? release)
               (> n 0)
               (not (has? mods (bitwise-ior mod-ctrl (bitwise-ior mod-alt mod-super)))))
      (y-pty-write key-bytes n))))

(define (on-key)
  (let* ((release (s32vector-ref ev 1))
         (repeat (s32vector-ref ev 2))
         (key (s32vector-ref ev 3))
         (mods (s32vector-ref ev 4))
         (unshifted (s32vector-ref ev 5))
         (is-mod (s32vector-ref ev 7))
         (utf-n (s32vector-ref ev 8))
         (bound (and (zero? release) (lookup-binding shortcuts key mods))))
    (if (and bound (run-key-shortcut bound))
        #f
        (begin
          (when (and (zero? release) (zero? is-mod))
            (y-clear-selection)
            (set! dirty? #t))
          (encode-key release repeat key mods unshifted utf-n)))))

(define (on-focus)
  (let ((in? (= (s32vector-ref ev 1) 1))
        (mode (s32vector-ref ev 2))
        (detail (s32vector-ref ev 3)))
    (unless (or (= mode 1) (= mode 2) (= detail 5))
      (unless (eq? focused? in?)
        (set! focused? in?)
        (when (= (y-focus-reporting) 1) (y-focus-write (if in? 1 0)))))))

(define (on-configure)
  (y-resize (s32vector-ref ev 1) (s32vector-ref ev 2))
  (sync-geom)
  (ensure-cells)
  (set! dirty? #t))

(define (dispatch kind)
  (cond ((= kind 1) (on-key))
        ((= kind 2) (on-button))
        ((= kind 3) (on-motion))
        ((= kind 4) (on-configure))
        ((= kind 5) (set! dirty? #t))
        ((= kind 6) (on-focus))
        ((= kind 7) (apply-paste! paste-clip?))
        ((= kind 8) (set! alive? #f))
        (else #f)))

(define (loop)
  (let drainx ()
    (if (and alive? (> (y-xpending) 0))
        (begin (dispatch (y-next-event ev)) (drainx))
        #f))
  (when alive?
    (let ((n (y-drain)))
      (when (= n 2) (set! dirty? #t))
      (when (= n 0) (set! alive? #f))))
  (when alive?
    (y-title)
    (let ((phase (blink-on?)))
      (when (or dirty? (not (eq? phase cursor-phase?)))
        (set! cursor-phase? phase)
        (draw)
        (y-swap)
        (set! dirty? #f)))
    (y-wait (y-blink-timeout (if (or text-blink? cursor-blinks?) 1 0))))
  (if alive? (loop) #f))

(define (yadatty)
  (make-atlas!)
  (y-configure cols rows min-cols min-rows blink-timeout-ms
               window-name window-class term-name colorterm fallback-shell)
  (cond ((not (zero? (y-init))) (y-shutdown) (exit 1))
        ((not (zero? (y-spawn))) (y-shutdown) (exit 1))
        (else
         (y-map)
         (sync-geom)
         (ensure-cells)
         (y-upload-atlas atlas-px atlas-w atlas-h)
         (loop)
         (y-shutdown)
         (exit 0))))

(yadatty)
