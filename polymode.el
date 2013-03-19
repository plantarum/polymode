;;; polymode.el --- support for multiple major modes
;; Author: Vitalie Spinu

(require 'font-lock)
(require 'imenu)
(require 'eieio)
(require 'eieio-base)
(require 'eieio-custom)
(require 'polymode-classes)
(require 'polymode-methods)
(require 'polymode-modes)

(defgroup polymode nil
  "Object oriented framework for multiple modes based on indirect buffers"
  :link '(emacs-commentary-link "polymode")
  :group 'tools)

(defgroup base-submodes nil
  "Base Submodes"
  :group 'polymode)

(defgroup submodes nil
  "Children Submodes"
  :group 'polymode)

(defvar polymode-select-mode-hook nil
  "Hook run after a different mode is selected.")

(defvar polymode-indirect-buffer-hook nil
  "Hook run by `pm/install-mode' in each indirect buffer.
It is run after all the indirect buffers have been set up.")

(defvar pm/fontify-region-original nil
  "Fontification function normally used by the buffer's major mode.
Used internaly to cahce font-lock-fontify-region-function.  Buffer local.")
(make-variable-buffer-local 'multi-fontify-region-original)


(defvar pm/base-mode nil)
(make-variable-buffer-local 'pm/base-mode)

(defvar pm/default-submode nil)
(make-variable-buffer-local 'pm/default-submode)

(defvar pm/config nil)
(make-variable-buffer-local 'pm/config)

(defvar pm/submode nil)
(make-variable-buffer-local 'pm/submode)

(defcustom polymode-prefix-key "\M-n"
  "Prefix key for the litprog mode keymap.
Not effective after loading the LitProg library."
  :group 'litprog
  :type '(choice string vector))

(defvar polymode-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map polymode-prefix-key
      (let ((map (make-sparse-keymap)))
	(define-key map "\C-n" 'litprog-next-header)
	(define-key map "\C-p" 'litprog-previous-header)
	;; (define-key map "\M-n" 'litprog-goto-next)
	;; (define-key map "\M-p" 'litprog-goto-prev)
	;; (define-key map "c" 'litprog-code-next)
	;; (define-key map "C" 'litprog-code-prev)
	;; (define-key map "d" 'litprog-doc-next)
	;; (define-key map "D" 'litprog-doc-prev)
        ;; Use imenu.
        ;; 	(define-key map "\C-g" 'litprog-goto-chunk)
        (define-key map "\M-k" 'litprog-kill-chunk)
        (define-key map "\M-K" 'litprog-kill-chunk-pair)
        (define-key map "\M-m" 'litprog-mark-chunk)
        (define-key map "\M-M" 'litprog-mark-chunk-pair)
        (define-key map "\M-n" 'litprog-narrow-to-chunk)
        (define-key map "\M-N" 'litprog-narrow-to-chunk-pair)
        (define-key map "\C-t" 'litprog-toggle-narrowing)
	(define-key map "\M-i" 'litprog-new-chunk)
	(define-key map "."	'litprog-select-backend)
	(define-key map "$"	'litprog-display-process)
	;; (if (bound-and-true-p litprog-electric-<)
	;;     (define-key litprog-mode-map "<" #'litprog-electric-<))
	;; (if (bound-and-true-p litprog-electric-@)
	;;     (define-key litprog-mode-map "@" #'litprog-electric-@))
	map))
    (define-key map [menu-bar LitProG]
      (cons "LitProG"
	    (let ((map (make-sparse-keymap "LitProG")))
              (define-key-after map [goto-prev]
		'(menu-item "Next chunk header" litprog-next-header))
	      (define-key-after map [goto-prev]
		'(menu-item "Previous chunk header" litprog-previous-header))
	      (define-key-after map [mark]
		'(menu-item "Mark chunk" litprog-mark-chunk))
	      (define-key-after map [kill]
		'(menu-item "Kill chunk" litprog-kill-chunk))
	      (define-key-after map [new]
		'(menu-item "New chunk" litprog-new-chunk))
	      map)))
    map)
  "A keymap for LitProG mode.")


(defsubst pm/base-buffer ()
  ;; fixme: redundant with :base-buffer 
  "Return base buffer of current buffer, or the current buffer if it's direct."
  (or (buffer-base-buffer (current-buffer))
      (current-buffer)))

;; ;; VS[26-08-2012]: Dave's comment:
;; ;; It would be nice to cache the results of this on text properties,
;; ;; but that probably won't work well if chunks can be nested.  In that
;; ;; case, you can't just mark everything between delimiters -- you have
;; ;; to consider other possible regions between them.  For now, we do
;; ;; the calculation each time, scanning outwards from point.
(defun pm/get-innermost-span (&optional pos)
  (pm/get-span pm/config pos))

(defun pm/map-over-spans (beg end fun)
  "For all spans between BEG and END, execute FUN.
FUN is a function of no args.  It is executed with point at the
beginning of the span and with the buffer narrowed to the
span.

During the call of FUN, a dynamically bound variable *span* hold
the current innermost span.
"
  (save-excursion
    (save-window-excursion ;; why is this here?
      (goto-char beg)
      (while (< (point) end)
        (let ((*span* (pm/get-innermost-span)))
          (pm/select-buffer (car (last *span*)) *span*) ;; object and type
          (save-restriction
            (pm/narrow-to-span *span*)
            (funcall fun)
            (goto-char (point-max)))
          )))))

(defun pm/narrow-to-span (&optional span)
  "Narrow to current chunk."
  (interactive)
  (if (boundp 'syntax-ppss-last)
      (setq syntax-ppss-last nil)) ;; fixme: why not let bind?
  (unless (= (point-min) (point-max))
    (let ((span (or span
                    (pm/get-innermost-span))))
      (if span 
          (narrow-to-region (nth 1 span) (nth 2 span))
        (error "No span found")))))

;; (defun pm--comment-region (&optional beg end buffer)
;;   ;; mark as syntactic comment
;;   (let ((beg (or beg (region-beginning)))
;;         (end (or end (region-end)))
;;         (buffer (or buffer (current-buffer))))
;;     (with-current-buffer buffer
;;       (with-silent-modifications
;;         (let ((ch-beg (char-after beg))
;;               (ch-end (char-before end)))
;;           (add-text-properties beg (1+ beg)
;;                                (list 'syntax-table (cons 11 ch-beg)
;;                                      'rear-nonsticky t
;;                                      'polymode-comment 'start))
;;           (add-text-properties (1- end) end
;;                                (list 'syntax-table (cons 12 ch-end)
;;                                      'rear-nonsticky t
;;                                      'polymode-comment 'end))
;;           )))))

;; (defun pm--remove-syntax-comment (&optional beg end buffer)
;;   ;; remove all syntax-table properties. Should not cause any problem as it is
;;   ;; always used before font locking
;;   (let ((beg (or beg (region-beginning)))
;;         (end (or end (region-end)))
;;         (buffer (or buffer (current-buffer))))
;;     (with-current-buffer buffer
;;       (with-silent-modifications
;;         (remove-text-properties beg end
;;                                 '(syntax-table nil rear-nonsticky nil polymode-comment nil))))))

;; ;; this one does't really work, text-properties are the same in all buffers
;; (defun pm--mark-buffers-except-current (beg end)
;;   ;; marke with syntact comments all the buffers except this on
;;   (dolist ((bf (oref pm/config :buffers)))
;;     (when (and (buffer-live-p bf)
;;                (not (eq bf (current-buffer))))
;;       (pm--comment-region beg end bf)
;;       ;; (put-text-property beg end 'fontified t)
;;       )))

;; (defun pm/fontify-region-simle (beg end &optional verbose)
;;   (with-silent-modifications
;;     (put-text-property beg end 'fontified t)))

(defun pm/fontify-region (beg end &optional verbose)
  "Polymode font-lock fontification function.
Fontifies chunk-by chunk within the region.
Assigned to `font-lock-fontify-region-function'.

A fontification mechanism should call
`font-lock-fontify-region-function' (`jit-lock-function' does
that). If it does not, the fontification will probably be screwed
in polymode buffers."
  (let* ((modified (buffer-modified-p))
         (buffer-undo-list t)
	 (inhibit-read-only t)
	 (inhibit-point-motion-hooks t)
	 (inhibit-modification-hooks t)
	 deactivate-mark)
    ;; (with-silent-modifications

    (save-restriction
      (widen)
      (pm/map-over-spans
       beg end
       (lambda ()
         ;; (message  "%s %s (%s %s) point: %s"
         ;;           (current-buffer) major-mode (point-min) (point-max) (point))
         (font-lock-unfontify-region (point-min) (point-max))
         (unwind-protect
             (progn ;; (dbg (point-min) (point-max) (current-buffer))
                    ;; (object-name (car (last *span*))))
                    (if (and font-lock-mode font-lock-keywords)
                        (funcall pm/fontify-region-original
                                 (point-min) (point-max) verbose)))
           ;; In case font-lock isn't done for some mode:
           (put-text-property (point-min) (point-max) 'fontified t))))
      (unless ,modified
        (restore-buffer-modified-p nil)))))


;;; internals
(defun pm--get-available-mode (mode)
  "Check if MODE symbol is defined and is a valid function.
If so, return it, otherwise return 'fundamental-mode with a
warnign."
  (if (fboundp mode)
      mode
    (message "Cannot find " mode " function, using 'fundamental-mode instead")
    'fundamental-mode))

(defvar pm--ignore-post-command-hook nil)
(defun pm--restore-ignore ()
  (setq pm--ignore-post-command-hook nil))
        
(defun polymode-select-buffer ()
  "Select the appropriate (indirect) buffer corresponding to point's context.
This funciton is placed in local post-command hook."
  ;; (condition-case error
  (unless pm--ignore-post-command-hook
    (let ((span (pm/get-innermost-span)))
      (pm/select-buffer (car (last span)) span))
    ;; urn post-command-hook at most every .01 seconds
    ;; fixme: should be more elaborated
    ;; (setq pm--ignore-post-command-hook t)
    ;; (run-with-timer .01 nil 'pm--restore-ignore))
    ;; (error
    ;;  (message "%s" (error-message-string error))))
  ))


(defun pm--adjust-visual-line-mode (new-vlm)
  (when (not (eq visual-line-mode vlm))
    (if (null vlm)
        (visual-line-mode -1)
      (visual-line-mode 1))))


(defun pm--select-buffer (buffer)
  (unless (eq buffer (current-buffer))
    (when (buffer-live-p buffer)
      (let* ((point (point))
             (window-start (window-start))
             (visible (pos-visible-in-window-p))
             (oldbuf (current-buffer))
             (vlm visual-line-mode)
             (ractive (region-active-p))
             (mkt (mark t)))
        (switch-to-buffer buffer)
        (pm--adjust-visual-line-mode vlm)
        (bury-buffer oldbuf)
        ;; fixme: wha tis the right way to do this ... activate-mark-hook?
        (if (not ractive)
            (deactivate-mark)
          (set-mark mkt)
          (activate-mark))
        (goto-char point)
        ;; Avoid the display jumping around.
        (when visible
          (set-window-start (get-buffer-window buffer t) window-start))
        ))))


(defun pm--setup-buffer (&optional buffer)
  ;; general buffer setup, should work for indirect and base buffers alike
  ;; assumes pm/config is already in place
  ;; return buffer
  (let ((buff (or buffer (current-buffer))))
    (with-current-buffer buff
      ;; Don't let parse-partial-sexp get fooled by syntax outside
      ;; the chunk being fontified.
      ;; font-lock, forward-sexp etc should see syntactic comments
      ;; (set (make-local-variable 'parse-sexp-lookup-properties) t)

      (set (make-local-variable 'font-lock-dont-widen) t)
      
      (when pm--dbg-fontlock 
        (setq pm/fontify-region-original
              font-lock-fontify-region-function)
        (set (make-local-variable 'font-lock-fontify-region-function)
             #'pm/fontify-region))

      (set (make-local-variable 'polymode-mode) t)
      (funcall (oref pm/config :minor-mode-name) t)



      ;; Indentation should first narrow to the chunk.  Modes
      ;; should normally just bind `indent-line-function' to
      ;; handle indentation.
      (when (and indent-line-function ; not that it should ever be nil...
                 (oref pm/submode :protect-indent-line-function))
        (set (make-local-variable 'indent-line-function)
             `(lambda ()
                (save-restriction
                  (pm/narrow-to-span)
                  (,indent-line-function)))))

      ;; Kill the base buffer along with the indirect one; careful not
      ;; to infloop.
      ;; (add-hook 'kill-buffer-hook
      ;;           '(lambda ()
      ;;              ;; (setq kill-buffer-hook nil) :emacs 24 bug (killing
      ;;              ;; dead buffer triggers an error)
      ;;              (let ((base (buffer-base-buffer)))
      ;;                (if  base
      ;;                    (unless (buffer-local-value 'pm--killed-once base)
      ;;                      (kill-buffer base))
      ;;                  (setq pm--killed-once t))))
      ;;           t t)
      
      ;; This should probably be at the front of the hook list, so
      ;; that other hook functions get run in the (perhaps)
      ;; newly-selected buffer.
      (when pm--dbg-hook
        (add-hook 'post-command-hook 'polymode-select-buffer nil t))
      (object-add-to-list pm/config :buffers (current-buffer)))
    buff))

(defvar pm--killed-once nil)
(make-variable-buffer-local 'pm--killed-once)


;; adapted from org
(defun pm--clone-local-variables (from-buffer &optional regexp)
  "Clone local variables from FROM-BUFFER.
Optional argument REGEXP selects variables to clone."
  (mapc
   (lambda (pair)
     (and (symbolp (car pair))
	  (or (null regexp)
	      (string-match regexp (symbol-name (car pair))))
          (condition-case error ;; some special wars cannot be set directly, how to solve?
              (set (make-local-variable (car pair))
                   (cdr pair))
            ;; fixme: enable-multibyte-characters cannot be set, what are others?
            (error ;(message  "--dbg local set: %s" (error-message-string error))
                   nil))))
   (buffer-local-variables from-buffer)))

(defun pm--create-indirect-buffer (mode)
  "Create indirect buffer with major MODE and initialize appropriately.

This is a low lever function which must be called, one way or
another from `pm/install' method. Among other things store
`pm/config' from the base buffer (must always exist!) in
the newly created buffer.

Return newlly created buffer."
  (unless   (buffer-local-value 'pm/config (pm/base-buffer))
    (error "`pm/config' not found in the base buffer %s" (pm/base-buffer)))
  
  (setq mode (pm--get-available-mode mode))
  ;; VS[26-08-2012]: The following if is Dave Love's hack in multi-mode. Kept
  ;; here, because i don't really understand it.

  ;; This is part of a grim hack for lossage in AUCTeX, which
  ;; bogusly advises `hack-one-local-variable'.  This loses, due to
  ;; the way advice works, when we run `pm/hack-local-variables'
  ;; below -- there ought to be a way round this, probably with CL's
  ;; flet.  Any subsequent use of it then fails because advice has
  ;; captured the now-unbound variable `late-hack'...  Thus ensure
  ;; we've loaded the mode in advance to get any autoloads sorted
  ;; out.  Do it generally in case other modes have similar
  ;; problems.  [The AUCTeX stuff is in support of an undocumented
  ;; feature which is unnecessary and, anyway, wouldn't need advice
  ;; to implement.  Unfortunately the maintainer seems not to
  ;; understand the local variables mechanism and wouldn't remove
  ;; this.  To invoke minor modes, you should just use `mode:' in
  ;; `local variables'.]
  ;; (if (eq 'autoload (car-safe (indirect-function mode)))
  ;;     (with-temp-buffer
  ;;       (insert "Local Variables:\nmode: fundamental\nEnd:\n")
  ;;       (funcall mode)
  ;;       (hack-local-variables)))

  (with-current-buffer (pm/base-buffer)
    (let* ((config (buffer-local-value 'pm/config (current-buffer)))
           (new-name
            (generate-new-buffer-name 
             (format "%s[%s]" (buffer-name)
                     (replace-regexp-in-string "-mode" "" (symbol-name mode)))))
           (new-buffer (make-indirect-buffer (current-buffer)  new-name))
           ;; (hook pm/indirect-buffer-hook)
           (file (buffer-file-name))
           (base-name (buffer-name))
           (jit-lock-mode nil)
           (coding buffer-file-coding-system)
           (tbf (get-buffer-create "*pm-tmp*")))

      ;; do it in empty buffer to exclude all kind of font-lock issues
      ;; Or, is there a reliable way to deactivate font-lock temporarly?
      (with-current-buffer tbf
        (let ((polymode-mode t)) ;;major-modes might check it
          (funcall mode)))
      (with-current-buffer new-buffer
        (pm--clone-local-variables tbf)
        ;; Now we can make it local:
        (setq polymode-major-mode mode)
        
        ;; VS[26-08-2012]: Dave Love's hack.
        ;; Use file's local variables section to set variables in
        ;; this buffer.  (Don't just copy local variables from the
        ;; base buffer because it may have set things locally that
        ;; we don't want in the other modes.)  We need to prevent
        ;; `mode' being processed and re-setting the major mode.
        ;; It all goes badly wrong if `hack-one-local-variable' is
        ;; advised.  The appropriate mechanism to get round this
        ;; appears to be `ad-with-originals', but we don't want to
        ;; pull in the advice package unnecessarily.  `flet'-like
        ;; mechanisms lose with advice because `fset' acts on the
        ;; advice anyway.
        ;; (if (featurep 'advice)
        ;;     (ad-with-originals (hack-one-local-variable)
        ;;       (pm/hack-local-variables))
        ;;   (pm/hack-local-variables))


        ;; Avoid the uniqified name for the indirect buffer in the
        ;; mode line.
        ;; (setq mode-line-buffer-identification
        ;;       (propertized-buffer-identification base-name))
        (setq pm/config config)
        
        (setq buffer-file-coding-system coding)
        ;; For benefit of things like VC
        (setq buffer-file-name file)
        (vc-find-file-hook))
      new-buffer)))


(defvar polymode-major-mode nil)
(make-variable-buffer-local 'polymode-major-mode)

(defun pm--get-indirect-buffer-of-mode (mode)
  (loop for bf in (oref pm/config :buffers)
        when (and (buffer-live-p bf)
                  (or (eq mode (buffer-local-value 'major-mode bf))
                      (eq mode (buffer-local-value 'polymode-major-mode bf))))
        return bf))

(defun pm--set-submode-buffer (obj type buff)
  (with-slots (buffer head-mode head-buffer tail-mode tail-buffer) obj
    (pcase (list type head-mode tail-mode)
      (`(body body ,(or `nil `body))
       (setq buffer buff
             head-buffer buff
             tail-buffer buff))
      (`(body ,_ body)
       (setq buffer buff
             tail-buffer buff))
      (`(body ,_ ,_ )
       (setq buffer buff))
      (`(head ,_ ,(or `nil `head))
       (setq head-buffer buff
             tail-buffer buff))
      (`(head ,_ ,_)
       (setq head-buffer buff))
      (`(tail ,_ ,(or `nil `head))
       (setq tail-buffer buff
             head-buffer buff))
      (`(tail ,_ ,_)
       (setq tail-buffer buff))
      (_ (error "type must be one of 'body 'head and 'tail")))))

;; (oref pm-submode/noweb-R :tail-mode)
;; (oref pm-submode/noweb-R :buffer)
;; (oref pm-submode/noweb-R :head-buffer)
;; (pm--set-submode-buffer pm-submode/noweb-R 'tail (current-buffer))

;;;; HACKS
;; VS[26-08-2012]: Dave Love's hack. See commentary above.
(defun pm/hack-local-variables ()
  "Like `hack-local-variables', but ignore `mode' items."
  (let ((late-hack (symbol-function 'hack-one-local-variable)))
    (fset 'hack-one-local-variable
	  (lambda (var val)
	    (unless (eq var 'mode)
	      (funcall late-hack var val))))
    (unwind-protect
	(hack-local-variables)
      (fset 'hack-one-local-variable late-hack))))


;; Used to propagate the bindings to the indirect buffers.
(define-minor-mode polymode-minor-mode
  "Polymode minor mode, used to make everything work."
  nil " PM" polymode-mode-map)

(define-derived-mode noweb-mode2 fundamental-mode "Noweb"
  "Mode for editing noweb documents.
Supports differnt major modes for doc and code chunks using multi-mode."
  (pm/initialize (clone pm-config/noweb-R)))

(add-to-list 'auto-mode-alist '("Tnw" . noweb-mode2))

(define-derived-mode Rmd-mode fundamental-mode "Rmd"
  "Mode for editing noweb documents.
Supports differnt major modes for doc and code chunks using multi-mode."
  (pm/initialize (clone pm-config/markdown)))

(define-minor-mode Rmd-minor-mode
  "Polymode minor mode, used to make everything work."
  nil " Rmd" polymode-mode-map
  (if Rmd-minor-mode
      (unless pm/config
        (let ((config (clone pm-config/markdown)))
          (oset config :minor-mode-name 'Rmd-minor-mode)
          (pm/initialize config)))
    (setq pm/config nil
          pm/submode nil)))

(add-to-list 'auto-mode-alist '("Rmd" . Rmd-mode))


(defun pm--map-over-spans-highlight ()
  (interactive)
  (pm/map-over-spans (point-min) (point-max)
                     (lambda ()
                       (let ((start (nth 1 *span*))
                             (end (nth 2 *span*)))
                         (ess-blink-region start end)
                         (sit-for 1)))))
(setq pm--dbg-fontlock t
      pm--dbg-hook t)

(provide 'polymode)
