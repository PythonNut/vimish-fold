;;; vimish-fold.el --- Fold text like in Vim -*- lexical-binding: t; -*-
;;
;; Copyright © 2015 Mark Karpov <markkarpov@openmailbox.org>
;; Copyright © 2012–2013 Magnar Sveen <magnars@gmail.com>
;;
;; Author: Mark Karpov <markkarpov@openmailbox.org>
;; Author: Magnar Sveen <magnars@gmail.com>
;; URL: https://github.com/mrkkrp/vimish-fold
;; Version: 0.1.0
;; Package-Requires: ((emacs "24.4") (cl-lib "0.5") (f "0.18.0"))
;; Keywords: convenience
;;
;; This file is not part of GNU Emacs.
;;
;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at your
;; option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
;; Public License for more details.
;;
;; You should have received a copy of the GNU General Public License along
;; with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This is package to do text folding like in Vim. It has the following
;; features:
;;
;; * batteries included: activate minor mode, bind a couple of commands and
;;   everything will just work;
;;
;; * it works on regions you select;
;;
;; * it's persistent: when you close file your folds don't disappear;
;;
;; * in addition to being persistent, it scales well, you can work on
;;   hundreds of files with lots of folds without adverse effects;
;;
;; * it's obvious which parts of text are folded;
;;
;; * it doesn't break indentation or something;
;;
;; * it can refold just unfolded folds (oh, my);
;;
;; * for fans of `avy' package: you can use `avy' to fold text with minimal
;;   number of key strokes!

;;; Code:

(require 'cl-lib)
(require 'f)

;; Basic Functionality

(defgroup vimish-fold nil
  "Fold text like in Vim"
  :group  'text
  :tag    "Vimish Fold"
  :prefix "vimish-fold-"
  :link   '(url-link :tag "GitHub" "https://github.com/mrkkrp/vimish-fold"))

(defface vimish-fold-overlay
  '((t (:inherit highlight)))
  "Face used to highlight the fold overlay.")

(defface vimish-fold-mouse-face
  '((t (:inherit highlight :weight bold)))
  "Face to use when mouse hovers over folded text.")

(defface vimish-fold-fringe
  '((t (:inherit font-lock-function-name-face)))
  "Face used to indicate folded text on fringe.")

(defcustom vimish-fold-indication-mode 'left-fringe
  "The indication mode for folded text areas.

This variable may have one of the following values:
`left-fringe', `right-fringe', or NIL.

If set to `left-fringe' or `right-fringe', indicate folded text
via icons in the left and right fringe respectively.

If set to NIL, do not indicate folded text, just highlight it."
  :tag "Indication on folded text"
  :type '(choice (const :tag "Indicate in the left fringe" left-fringe)
                 (const :tag "Indicate in the right fringe" right-fringe)
                 (const :tag "Do not indicate" nil)))

(defcustom vimish-fold-blank-fold-header "<blank fold>"
  "The string is used as fold header when it consists of blank characters."
  :tag  "Header of Blank Fold"
  :type 'string)

(defvar vimish-fold--recently-unfolded nil
  "List of (BEG END) lists represented recently unfolded regions.

This is used by `vimish-fold-refold'.")

(defvar vimish-fold-keymap (make-sparse-keymap)
  "Keymap which is active when point is placed on folded text.")

(defun vimish-fold--correct-region (beg end)
  "Return a cons of corrected BEG and END.

We only support folding by whole lines, so we should make sure
that beginning and end positions are correct.  Also, sometimes
users select region including last newline into it, they don't
really want to include it, we correct this here."
  (cl-destructuring-bind (beg . end)
      (if (>= end beg)
          (cons beg end)
        (cons end beg))
    (save-excursion
      (let* ((beg* (progn (goto-char beg)
                          (line-beginning-position)))
             (end* (progn (goto-char end)
                          (if (and (zerop (current-column))
                                   (/= end beg*))
                              (1- end)
                            (line-end-position)))))
        (cons beg* end*)))))

(defun vimish-fold--read-only (on beg end)
  "If ON is non-NIL, make text between BEG and END read-only.

If ON is NIL, make the text editable again."
  (let ((inhibit-read-only t))
    (with-silent-modifications
      (funcall
       (if on #'set-text-properties #'remove-text-properties)
       beg end (list 'read-only on)))))

(defun vimish-fold--get-header (beg end)
  "Extract folding header from region between BEG and END in BUFFER.

If BUFFER is NIL, current buffer is used."
  (save-excursion
    (goto-char beg)
    (re-search-forward "^\\([[:blank:]]*.+\\)$")
    (if (and (>= (match-beginning 1) beg)
             (<= (match-end 1)       end))
        (match-string-no-properties 1)
      vimish-fold-blank-fold-header)))

(defun vimish-fold--apply-cosmetic (overlay header)
  "Make OVERLAY look according to user's settings displaying HEADER.

This includes fringe bitmaps and faces."
  (overlay-put overlay 'display
               (propertize header 'face 'vimish-fold-overlay))
  (overlay-put overlay 'pointer 'hand)
  (overlay-put overlay 'mouse-face 'vimish-fold-mouse-face)
  (overlay-put overlay 'help-echo "Click to unfold the text")
  (when vimish-fold-indication-mode
    (unless (memq vimish-fold-indication-mode
                  '(left-fringe right-fringe))
      (error "Invalid fringe side: %S"
             vimish-fold-indication-mode))
    (overlay-put overlay 'before-string
                 (propertize "…" 'display
                             (list vimish-fold-indication-mode
                                   'empty-line
                                   'vimish-fold-fringe)))))

;;;###autoload
(defun vimish-fold (beg end)
  "Fold active region staring at BEG, ending at END."
  (interactive "r")
  (deactivate-mark)
  (cl-destructuring-bind (beg . end) (vimish-fold--correct-region beg end)
    (when (= beg end)
      (error "Nothing to fold"))
    (dolist (overlay (overlays-in beg end))
      (when (eq (overlay-get overlay 'type) 'vimish-fold)
        (goto-char (overlay-start overlay))
        (error "Something is already folded here")))
    (vimish-fold--read-only t (max 1 (1- beg)) end)
    (let ((overlay (make-overlay beg end nil t nil)))
      (overlay-put overlay 'type 'vimish-fold)
      (overlay-put overlay 'keymap vimish-fold-keymap)
      (vimish-fold--apply-cosmetic overlay (vimish-fold--get-header beg end)))
    (goto-char beg)))

(defun vimish-fold--unfold (overlay)
  "Delete OVERLAY if its type is `vimish-fold'."
  (when (eq (overlay-get overlay 'type) 'vimish-fold)
    (let ((beg (overlay-start overlay))
          (end (overlay-end   overlay)))
      (vimish-fold--read-only nil (max 1 (1- beg)) end)
      (delete-overlay overlay)
      (setq-local vimish-fold--recently-unfolded
                  (cons (list beg end)
                        vimish-fold--recently-unfolded)))))

;;;###autoload
(defun vimish-fold-unfold ()
  "Delete all `vimish-fold' overlays at point."
  (interactive)
  (setq-local vimish-fold--recently-unfolded nil)
  (dolist (overlay (overlays-at (point)))
    (vimish-fold--unfold overlay)))

(define-key vimish-fold-keymap (kbd "<mouse-1>") #'vimish-fold-unfold)
(define-key vimish-fold-keymap (kbd "C-g")       #'vimish-fold-unfold)
(define-key vimish-fold-keymap (kbd "RET")       #'vimish-fold-unfold)

;;;###autoload
(defun vimish-fold-unfold-all ()
  "Unfold all folds in current buffer."
  (interactive)
  (setq-local vimish-fold--recently-unfolded nil)
  (dolist (overlay (overlays-in (point-min) (point-max)))
    (vimish-fold--unfold overlay))
  (unless vimish-fold--recently-unfolded
    (message "Nothing to unfold")))

(defun vimish-fold--restore-from (list)
  "Restore folds in current buffer form LIST.

Elements of LIST should be of the following form:

  (BEG END)"
  (save-excursion
    (dolist (item list)
      (apply #'vimish-fold item))
    (setq-local vimish-fold--recently-unfolded nil)))

;;;###autoload
(defun vimish-fold-refold ()
  "Refold recently unfolded folds."
  (interactive)
  (if vimish-fold--recently-unfolded
      (vimish-fold--restore-from vimish-fold--recently-unfolded)
    (message "Nothing to refold")))

;;;###autoload
(defun vimish-fold-avy ()
  "Fold region of text between point and line selected with avy.

This feature needs `avy' package."
  (interactive)
  (if (require 'avy nil t)
      (let ((beg (point))
            (end (progn (call-interactively #'avy-goto-line)
                        (point))))
        (vimish-fold beg end))
    (message "Package ‘avy’ is unavailable")))

;; Persistence

(defcustom vimish-fold-dir
  (file-name-as-directory (f-expand "vimish-fold" user-emacs-directory))
  "The directory where Vimish Fold keeps its files.

The string should end with a slash.  If it doesn't exist, it will
be created automatically."
  :tag   "Directory for Folding Info"
  :type  'directory)

(defun vimish-fold--make-file-name (file)
  "Return path to file where information about folding in FILE is written."
  (f-expand
   (replace-regexp-in-string
    (regexp-quote (f-path-separator))
    "!"
    file)
   vimish-fold-dir))

(defun vimish-fold--save-folds (&optional buffer-or-name)
  "Save folds in BUFFER-OR-NAME, which should have associated file.

BUFFER-OR-NAME defaults to current buffer."
  (with-current-buffer (or buffer-or-name (current-buffer))
    (let ((filename (buffer-file-name))
          regions)
      (when filename
        (dolist (overlay (overlays-in (point-min) (point-max)))
          (when (eq (overlay-get overlay 'type) 'vimish-fold)
            (push (list (overlay-start overlay)
                        (overlay-end   overlay))
                  regions)))
        (let ((fold-file (vimish-fold--make-file-name filename)))
          (if regions
              (with-temp-buffer
                (insert (format ";;; -*- coding: %s -*-\n"
                                (symbol-name coding-system-for-write)))
                (pp regions (current-buffer))
                (let ((version-control 'never))
                  (condition-case nil
                      (progn
                        (f-mkdir vimish-fold-dir)
                        (write-region (point-min) (point-max) fold-file)
                        nil)
                    (file-error
                     (message "Vimish Fold: can't write %s" fold-file)))
                  (kill-buffer (current-buffer))))
            (when (f-exists? fold-file)
              (f-delete fold-file))))))))

(defun vimish-fold--restore-folds (&optional buffer-or-name)
  "Restore folds in BUFFER-OR-NAME, if they have been saved.

BUFFER-OR-NAME defaults to current buffer.

Return T is some folds have been restored and NIL otherwise."
  (with-current-buffer (or buffer-or-name (current-buffer))
    (let ((filename (buffer-file-name)))
      (when filename
        (let ((fold-file (vimish-fold--make-file-name filename)))
          (when (and fold-file (f-readable? fold-file))
            (vimish-fold--restore-from
             (with-temp-buffer
               (insert-file-contents fold-file)
               (read (buffer-string))))))))))

(defun vimish-fold--kill-emacs-hook ()
  "Traverse all buffers and try to save their folds."
  (mapc #'vimish-fold--save-folds (buffer-list)))

;;;###autoload
(define-minor-mode vimish-fold-mode
  "Toggle `vimish-fold-mode' minor mode.

With a prefix argument ARG, enable `vimish-fold-mode' mode if ARG
is positive, and disable it otherwise.  If called from Lisp,
enable the mode if ARG is omitted or NIL, and toggle it if ARG is
`toggle'.

This minor mode sets hooks so when you `find-file' it calls
`vimish-fold--restore-folds' and when you kill a file it calls
`vimish-fold--save-folds'.

For globalized version of this mode see `vimish-gold-global-mode'."
  :global nil
  (let ((fnc (if vimish-fold-mode #'add-hook #'remove-hook)))
    (funcall fnc 'find-file-hook   #'vimish-fold--restore-folds)
    (funcall fnc 'kill-buffer-hook #'vimish-fold--save-folds)
    (funcall fnc 'kill-emacs-hook  #'vimish-fold--kill-emacs-hook)))

;;;###autoload
(define-globalized-minor-mode vimish-fold-global-mode
  vimish-fold-mode vimish-fold-mode)

(provide 'vimish-fold)

;;; vimish-fold.el ends here
