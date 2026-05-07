;;; agent-shell-pet.el --- Animated pets for agent-shell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Luis Moneda

;; Author: Luis Moneda
;; URL: https://github.com/lgmoneda/agent-shell-pet
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.50.1"))
;; Keywords: tools, ai, convenience

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; agent-shell-pet displays Codex-compatible animated pet sprites while
;; `agent-shell' buffers are active.  It reuses the same custom pet package
;; format as Codex.app:
;;
;;   ${CODEX_HOME:-$HOME/.codex}/pets/<pet-id>/pet.json
;;   ${CODEX_HOME:-$HOME/.codex}/pets/<pet-id>/spritesheet.webp
;;
;; The portable renderer uses an Emacs child frame.  On macOS, an optional
;; AppKit helper can render a Codex-like floating pet above other applications.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-parse)

(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-unsubscribe "agent-shell")

(defgroup agent-shell-pet nil
  "Animated pets for agent-shell."
  :group 'agent-shell
  :prefix "agent-shell-pet-")

(defface agent-shell-pet-speech-bubble
  '((t :inherit default
       :box (:line-width 6 :style released-button)))
  "Face used for the child-frame pet speech bubble."
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-id nil
  "Pet id to use.

When nil, use the first discovered custom pet."
  :type '(choice (const :tag "First available" nil) string)
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-codex-home
  (or (getenv "CODEX_HOME") (expand-file-name "~/.codex"))
  "Directory containing Codex configuration and custom pets."
  :type 'directory
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-user-pets-directory
  (locate-user-emacs-file "agent-shell-pet/pets/")
  "Directory where agent-shell-pet installs pets for users without Codex."
  :type 'directory
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-bundled-pets-directory
  (expand-file-name
   "pets/"
   (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Directory containing pets bundled with agent-shell-pet."
  :type 'directory
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-include-codex-pets t
  "Non-nil to discover pets installed for Codex under `agent-shell-pet-codex-home'."
  :type 'boolean
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-install-target 'agent-shell-pet
  "Default target directory for `agent-shell-pet-install-from-codex-pets'.

`agent-shell-pet' installs into `agent-shell-pet-user-pets-directory'.
`codex' installs into the Codex-compatible pets directory under
`agent-shell-pet-codex-home'."
  :type '(choice (const :tag "agent-shell-pet" agent-shell-pet)
                 (const :tag "Codex" codex))
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-codex-pets-api-base
  "https://ihzwckyzfcuktrljwpha.supabase.co/functions/v1/petshare"
  "Base URL for the public Codex Pets API."
  :type 'string
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-cache-directory
  (expand-file-name "agent-shell-pet/cache/" user-emacs-directory)
  "Directory where extracted pet frames are cached."
  :type 'directory
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-renderer
  'child-frame
  "Renderer backend.

`child-frame' renders inside Emacs.  `macos-native' uses a tiny AppKit helper
window that can float above other applications."
  :type '(choice (const :tag "Emacs child frame" child-frame)
                 (const :tag "macOS native helper" macos-native))
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-scope 'global
  "Scope used by `global-agent-shell-pet-mode'.

`global' keeps one Codex-like pet overlay and aggregates activity from all
agent-shell buffers.  `buffer' keeps the older one-pet-per-buffer behavior."
  :type '(choice (const :tag "One global pet" global)
                 (const :tag "One pet per buffer" buffer))
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-max-notifications 3
  "Maximum number of activity cards shown by the global pet."
  :type 'integer
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-dismiss-notification-on-buffer-visit t
  "Non-nil to dismiss a global notification when its agent-shell buffer is visited."
  :type 'boolean
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-macos-helper-path
  (expand-file-name
   "renderers/macos/agent-shell-pet-macos-renderer"
   (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Path to the macOS native renderer helper."
  :type 'file
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-scale 1.0
  "Additional multiplier applied after `agent-shell-pet-size'."
  :type 'number
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-size 'large
  "Preset size for the pet.

`large' keeps the original size.  `medium' and `small' make the pet more
compact while preserving the same Codex-compatible spritesheet frames."
  :type '(choice (const :tag "Large" large)
                 (const :tag "Medium" medium)
                 (const :tag "Small" small))
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-position 'bottom-right
  "Default child-frame pet position."
  :type '(choice (const bottom-right)
                 (const bottom-left)
                 (const top-right)
                 (const top-left))
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-margin-x 24
  "Horizontal margin in pixels for the child-frame renderer."
  :type 'integer
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-margin-y 24
  "Vertical margin in pixels for the child-frame renderer."
  :type 'integer
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-frame-extractor-command "magick"
  "Command used to extract frames from a Codex pet atlas.

The command must be ImageMagick 7 compatible.  The legacy `convert' command
also works for most installations if this value is changed."
  :type 'string
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-enabled-states
  '(idle running-right running-left waving jumping failed waiting running review)
  "Pet animation states to extract and play."
  :type '(repeat symbol)
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-show-speech-bubble t
  "Non-nil to show a speech bubble when the pet has state text.

The bubble is hidden while idle unless `agent-shell-pet-show-idle-speech-bubble'
is non-nil."
  :type 'boolean
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-show-idle-speech-bubble nil
  "Non-nil to show the speech bubble while the pet is idle."
  :type 'boolean
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-speech-bubble-height 44
  "Height in pixels reserved for the child-frame speech bubble."
  :type 'integer
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-speech-bubble-theme 'dark
  "Visual theme for pet speech bubbles and native activity cards."
  :type '(choice (const :tag "Dark" dark)
                 (const :tag "Light" light))
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-macos-card-title-function
  #'agent-shell-pet--default-card-title
  "Function called with RUNTIME to produce the macOS notification card title."
  :type 'function
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-idle-status-text nil
  "Status text shown when the pet is idle."
  :type '(choice (const :tag "No idle text" nil) string)
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-thinking-status-text "Thinking"
  "Status text shown after input is submitted and before richer activity arrives."
  :type '(choice (const :tag "No thinking text" nil) string)
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-chatty nil
  "Non-nil to show speech bubbles for routine completed turns."
  :type 'boolean
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-completion-display-seconds 10.0
  "Seconds to show the turn-complete state before returning to idle."
  :type 'number
  :group 'agent-shell-pet)

(defcustom agent-shell-pet-speech-style 'pet
  "Style used for speech bubble text.

`pet' keeps phrases short and mascot-like.  `technical' keeps more tool detail."
  :type '(choice (const pet) (const technical))
  :group 'agent-shell-pet)

(defconst agent-shell-pet--atlas-width 1536)
(defconst agent-shell-pet--atlas-height 1872)
(defconst agent-shell-pet--cell-width 192)
(defconst agent-shell-pet--cell-height 208)

(defconst agent-shell-pet--state-specs
  '((idle . (:row 0 :durations (280 110 110 140 140 320)))
    (running-right . (:row 1 :durations (120 120 120 120 120 120 120 220)))
    (running-left . (:row 2 :durations (120 120 120 120 120 120 120 220)))
    (waving . (:row 3 :durations (140 140 140 280)))
    (jumping . (:row 4 :durations (140 140 140 140 280)))
    (failed . (:row 5 :durations (140 140 140 140 140 140 140 240)))
    (waiting . (:row 6 :durations (150 150 150 150 150 260)))
    (running . (:row 7 :durations (120 120 120 120 120 220)))
    (review . (:row 8 :durations (150 150 150 150 150 280)))))

(cl-defstruct (agent-shell-pet
               (:constructor agent-shell-pet--make))
  id display-name description directory spritesheet-path)

(cl-defstruct (agent-shell-pet--runtime
               (:constructor agent-shell-pet--make-runtime))
  pet shell-buffer renderer state status-text frame-index timer subscriptions
  transient-timer child-frame child-buffer native-process global-display-p
  updated-at dismissed-at)

(defvar-local agent-shell-pet--runtime nil
  "Buffer-local pet runtime.")

(defvar agent-shell-pet--global-runtime nil
  "Display runtime used for the global pet overlay.")

(defvar agent-shell-pet--global-runtimes (make-hash-table :test #'eq)
  "Agent-shell buffer runtimes currently contributing to the global pet.")

(defvar agent-shell-pet--global-display-suppressed nil
  "Non-nil when the user has hidden the global pet via `agent-shell-pet-hide'.
While suppressed, frame updates and `agent-shell-pet--global-refresh' are
skipped so the pet stays hidden across all agent-shell buffers until
`agent-shell-pet-show' is called.")

(defvar global-agent-shell-pet-mode nil
  "Non-nil when `global-agent-shell-pet-mode' is enabled.")

(defun agent-shell-pet--runtime-live-p (runtime)
  "Return non-nil when RUNTIME looks compatible with this package version."
  (condition-case nil
      (and (agent-shell-pet--runtime-p runtime)
           (agent-shell-pet-p (agent-shell-pet--runtime-pet runtime))
           (or (agent-shell-pet--runtime-global-display-p runtime)
               (buffer-live-p (agent-shell-pet--runtime-shell-buffer runtime)))
           (memq (agent-shell-pet--runtime-renderer runtime)
                 '(child-frame macos-native global))
           (symbolp (agent-shell-pet--runtime-state runtime))
           (alist-get (agent-shell-pet--runtime-state runtime)
                      agent-shell-pet--state-specs)
           (natnump (agent-shell-pet--runtime-frame-index runtime))
           (or (null (agent-shell-pet--runtime-status-text runtime))
               (stringp (agent-shell-pet--runtime-status-text runtime))))
    (error nil)))

(defun agent-shell-pet--cancel-pet-timers ()
  "Cancel all currently scheduled agent-shell-pet animation timers."
  (dolist (timer (append timer-list timer-idle-list))
    (when (and (timerp timer)
               (memq (timer--function timer)
                     '(agent-shell-pet--tick
                       agent-shell-pet--set-state)))
      (cancel-timer timer))))

(defun agent-shell-pet--pets-directory ()
  "Return the Codex-compatible custom pets directory."
  (expand-file-name "pets/" agent-shell-pet-codex-home))

(defun agent-shell-pet--pet-roots ()
  "Return pet root directories in discovery preference order."
  (delq nil
        (list agent-shell-pet-user-pets-directory
              (when agent-shell-pet-include-codex-pets
                (agent-shell-pet--pets-directory))
              agent-shell-pet-bundled-pets-directory)))

(defun agent-shell-pet--install-directory (&optional target)
  "Return pet install directory for TARGET."
  (pcase (or target agent-shell-pet-install-target)
    ('codex (agent-shell-pet--pets-directory))
    (_ agent-shell-pet-user-pets-directory)))

(defun agent-shell-pet--read-json-file (file)
  "Read FILE as a JSON object alist."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol))
    (json-read-file file)))

(defun agent-shell-pet--path-contained-p (parent child)
  "Return non-nil when CHILD resolves lexically inside PARENT.

Uses `expand-file-name' rather than `file-truename' so that legitimate
symlinks inside PARENT are not rejected — package managers like
straight.el commonly stage non-Lisp resources into the build directory
as symlinks pointing back into the source repo.  Path-traversal
attempts in the manifest (`..', absolute paths, `~') are still caught
because `expand-file-name' resolves them lexically without touching
the filesystem."
  (let* ((parent (file-name-as-directory (expand-file-name parent)))
         (child (expand-file-name child)))
    (string-prefix-p parent child)))

(defun agent-shell-pet--png-size (file)
  "Return FILE PNG dimensions as (WIDTH . HEIGHT), or nil."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 24)
    (let ((data (buffer-string)))
      (when (and (>= (length data) 24)
                 (string= (substring data 0 8) "\211PNG\r\n\032\n")
                 (string= (substring data 12 16) "IHDR"))
        (cons (+ (ash (aref data 16) 24)
                 (ash (aref data 17) 16)
                 (ash (aref data 18) 8)
                 (aref data 19))
              (+ (ash (aref data 20) 24)
                 (ash (aref data 21) 16)
                 (ash (aref data 22) 8)
                 (aref data 23)))))))

(defun agent-shell-pet--webp-size (file)
  "Return FILE WebP dimensions as (WIDTH . HEIGHT), or nil."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (let ((data (buffer-string)))
      (when (and (>= (length data) 30)
                 (string= (substring data 0 4) "RIFF")
                 (string= (substring data 8 12) "WEBP"))
        (cl-labels ((u16le (pos)
                      (+ (aref data pos)
                         (ash (aref data (1+ pos)) 8)))
                    (u24le (pos)
                      (+ (aref data pos)
                         (ash (aref data (1+ pos)) 8)
                         (ash (aref data (+ pos 2)) 16)))
                    (u32le (pos)
                      (+ (aref data pos)
                         (ash (aref data (1+ pos)) 8)
                         (ash (aref data (+ pos 2)) 16)
                         (ash (aref data (+ pos 3)) 24))))
          (catch 'size
            (let ((pos 12)
                  (len (length data)))
              (while (<= (+ pos 8) len)
                (let* ((chunk (substring data pos (+ pos 4)))
                       (size (u32le (+ pos 4)))
                       (payload (+ pos 8)))
                  (cond
                   ((and (string= chunk "VP8X") (<= (+ payload 10) len))
                    (throw 'size
                           (cons (1+ (u24le (+ payload 4)))
                                 (1+ (u24le (+ payload 7))))))
                   ((and (string= chunk "VP8 ") (<= (+ payload 10) len))
                    (let ((start (+ payload 6)))
                      (when (and (= (aref data start) #x9d)
                                 (= (aref data (1+ start)) #x01)
                                 (= (aref data (+ start 2)) #x2a))
                        (throw 'size
                               (cons (logand (u16le (+ start 3)) #x3fff)
                                     (logand (u16le (+ start 5)) #x3fff))))))
                   ((and (string= chunk "VP8L") (<= (+ payload 5) len)
                         (= (aref data payload) #x2f))
                    (let* ((b0 (aref data (1+ payload)))
                           (b1 (aref data (+ payload 2)))
                           (b2 (aref data (+ payload 3)))
                           (b3 (aref data (+ payload 4)))
                           (width (1+ (logand (+ b0 (ash b1 8)) #x3fff)))
                           (height (1+ (logand (+ (ash b1 -6)
                                                  (ash b2 2)
                                                  (ash b3 10))
                                               #x3fff))))
                      (throw 'size (cons width height)))))
                  (setq pos (+ payload size (if (cl-oddp size) 1 0)))))
              nil)))))))

(defun agent-shell-pet--image-size (file)
  "Return FILE dimensions as (WIDTH . HEIGHT), or nil."
  (or (agent-shell-pet--png-size file)
      (agent-shell-pet--webp-size file)))

(defun agent-shell-pet--valid-atlas-p (file)
  "Return non-nil when FILE is a Codex pet atlas."
  (equal (agent-shell-pet--image-size file)
         (cons agent-shell-pet--atlas-width agent-shell-pet--atlas-height)))

(defun agent-shell-pet--load-pet (directory)
  "Load a Codex-compatible pet from DIRECTORY, or return nil."
  (let ((manifest (expand-file-name "pet.json" directory)))
    (when (file-readable-p manifest)
      (condition-case nil
          (let* ((data (agent-shell-pet--read-json-file manifest))
                 (id (or (alist-get 'id data) (file-name-nondirectory
                                               (directory-file-name directory))))
                 (spritesheet-name (or (alist-get 'spritesheetPath data)
                                       "spritesheet.webp"))
                 (spritesheet (expand-file-name spritesheet-name directory)))
            (when (and (stringp id)
                       (not (string-empty-p id))
                       (file-readable-p spritesheet)
                       (agent-shell-pet--path-contained-p directory spritesheet)
                       (agent-shell-pet--valid-atlas-p spritesheet))
              (agent-shell-pet--make
               :id id
               :display-name (or (alist-get 'displayName data) id)
               :description (alist-get 'description data)
               :directory directory
               :spritesheet-path spritesheet)))
        (error nil)))))

;;;###autoload
(defun agent-shell-pet-list-pets ()
  "Return discovered Codex-compatible custom pets."
  (let ((seen (make-hash-table :test #'equal))
        pets)
    (dolist (root (agent-shell-pet--pet-roots))
      (when (file-directory-p root)
        (dolist (file (directory-files root t directory-files-no-dot-files-regexp))
          (when-let* (((file-directory-p file))
                      (pet (agent-shell-pet--load-pet file))
                      (id (agent-shell-pet-id pet))
                      ((not (gethash id seen))))
            (puthash id t seen)
            (push pet pets)))))
    (nreverse pets)))

(defun agent-shell-pet--select-pet ()
  "Return the selected pet, or signal when no valid pet exists."
  (let* ((pets (agent-shell-pet-list-pets))
         (pet (if agent-shell-pet-id
                  (seq-find (lambda (pet)
                              (equal (agent-shell-pet-id pet) agent-shell-pet-id))
                            pets)
                (car pets))))
    (unless pet
      (user-error "No Codex-compatible pet found under %s"
                  (mapconcat #'identity (agent-shell-pet--pet-roots) ", ")))
    pet))

(defun agent-shell-pet--pet-choice-label (pet)
  "Return a completion label for PET."
  (let ((id (agent-shell-pet-id pet))
        (display-name (agent-shell-pet-display-name pet)))
    (if (or (null display-name)
            (string-empty-p display-name)
            (equal display-name id))
        id
      (format "%s (%s)" display-name id))))

(defun agent-shell-pet--read-pet (&optional prompt)
  "Read a discovered pet with completion using PROMPT."
  (let* ((pets (agent-shell-pet-list-pets))
         (choices (mapcar (lambda (pet)
                            (cons (agent-shell-pet--pet-choice-label pet) pet))
                          pets))
         (current-label
          (when agent-shell-pet-id
            (car (seq-find
                  (lambda (choice)
                    (equal (agent-shell-pet-id (cdr choice)) agent-shell-pet-id))
                  choices)))))
    (unless choices
      (user-error "No Codex-compatible pet found under %s"
                  (mapconcat #'identity (agent-shell-pet--pet-roots) ", ")))
    (let ((selection (completing-read (or prompt "Select avatar: ")
                                      choices nil t nil nil current-label)))
      (cdr (assoc selection choices)))))

(defun agent-shell-pet--active-runtimes ()
  "Return live pet runtimes known to this Emacs session."
  (let (runtimes)
    (when (agent-shell-pet--runtime-live-p agent-shell-pet--global-runtime)
      (push agent-shell-pet--global-runtime runtimes))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (agent-shell-pet--runtime-live-p agent-shell-pet--runtime)
          (push agent-shell-pet--runtime runtimes))))
    (seq-uniq (nreverse runtimes) #'eq)))

(defun agent-shell-pet--switch-runtime-pet (runtime pet)
  "Switch RUNTIME to PET without rebuilding its renderer."
  (when (agent-shell-pet--runtime-live-p runtime)
    (setf (agent-shell-pet--runtime-pet runtime) pet)
    (setf (agent-shell-pet--runtime-frame-index runtime) 0)
    (when (agent-shell-pet--display-runtime-p runtime)
      (unless (and (agent-shell-pet--runtime-global-display-p runtime)
                   agent-shell-pet--global-display-suppressed)
        (agent-shell-pet--renderer-set-frame
         runtime
         (agent-shell-pet--current-frame-path runtime))
        (agent-shell-pet--schedule-next-frame runtime)))))

(defun agent-shell-pet--switch-active-pets (pet)
  "Switch all active runtimes to PET in place."
  (dolist (runtime (agent-shell-pet--active-runtimes))
    (agent-shell-pet--switch-runtime-pet runtime pet))
  (agent-shell-pet--global-refresh))

;;;###autoload
(defun agent-shell-pet-select-avatar (pet)
  "Select the avatar used by agent-shell-pet.

Interactively, prompt with completion over all discovered pets.  When a pet is
already active, switch its runtime in place without rebuilding the renderer."
  (interactive (list (agent-shell-pet--read-pet)))
  (unless (agent-shell-pet-p pet)
    (user-error "Invalid pet selection"))
  (setq agent-shell-pet-id (agent-shell-pet-id pet))
  (agent-shell-pet--ensure-frame-cache pet)
  (agent-shell-pet--switch-active-pets pet)
  (message "agent-shell-pet avatar: %s" (agent-shell-pet--pet-choice-label pet))
  pet)

(defun agent-shell-pet--codex-pets-url (path)
  "Return Codex Pets API URL for PATH."
  (concat (string-remove-suffix "/" agent-shell-pet-codex-pets-api-base)
          path))

(defun agent-shell-pet--codex-pets-read-json (url)
  "Read JSON from URL as an alist."
  (let ((buffer (url-retrieve-synchronously url t t 30)))
    (unless buffer
      (user-error "Failed to retrieve %s" url))
    (with-current-buffer buffer
      (unwind-protect
          (progn
            (goto-char (point-min))
            (unless (re-search-forward "\n\n" nil t)
              (error "No HTTP response body from %s" url))
            (let ((json-object-type 'alist)
                  (json-array-type 'list)
                  (json-key-type 'symbol))
              (json-read)))
        (kill-buffer buffer)))))

(defun agent-shell-pet--codex-pets-id-from-input (input)
  "Return a likely Codex Pets id from INPUT.

INPUT may be a plain id or a codex-pets.net URL."
  (let ((input (string-trim input)))
    (cond
     ((string-match "\\`[[:alnum:]_.-]+\\'" input)
      input)
     ((string-match "/\\(?:pets\\|share\\)/\\([[:alnum:]_.-]+\\)" input)
      (match-string 1 input))
     ((string-match "[?&]q=\\([^&#]+\\)" input)
      (url-unhex-string (match-string 1 input)))
     (t input))))

(defun agent-shell-pet--codex-pets-download-url (pet-data)
  "Return absolute download URL from PET-DATA."
  (let ((url (alist-get 'downloadUrl pet-data)))
    (unless (and (stringp url) (not (string-empty-p url)))
      (error "Codex Pets response did not include a download URL"))
    (if (string-prefix-p "http" url)
        url
      (agent-shell-pet--codex-pets-url url))))

(defun agent-shell-pet--safe-delete-directory (root directory)
  "Delete DIRECTORY when it is inside ROOT."
  (when (and (file-directory-p directory)
             (agent-shell-pet--path-contained-p root directory))
    (delete-directory directory t)))

;;;###autoload
(defun agent-shell-pet-install-from-codex-pets (input &optional target)
  "Install a pet from codex-pets.net.

INPUT can be a plain pet id, a /pets/<id> URL, a /share/<id> URL, or a gallery
search URL such as https://codex-pets.net/#/?q=goku.

TARGET can be `agent-shell-pet' or `codex'.  Interactively, a prefix argument
installs to Codex; otherwise use `agent-shell-pet-install-target'."
  (interactive
   (list (read-string "Codex Pets id or URL: ")
         (when current-prefix-arg 'codex)))
  (let* ((pet-id (agent-shell-pet--codex-pets-id-from-input input))
         (install-root (agent-shell-pet--install-directory target))
         (metadata (agent-shell-pet--codex-pets-read-json
                    (agent-shell-pet--codex-pets-url
                     (format "/api/pets/%s" (url-hexify-string pet-id)))))
         (pet-data (alist-get 'pet metadata))
         (download-url (agent-shell-pet--codex-pets-download-url pet-data))
         (target-directory (expand-file-name pet-id install-root))
         (zip-file (make-temp-file (format "agent-shell-pet-%s-" pet-id)
                                   nil ".codex-pet.zip")))
    (unwind-protect
        (progn
          (make-directory install-root t)
          (url-copy-file download-url zip-file t)
          (agent-shell-pet--safe-delete-directory install-root target-directory)
          (make-directory target-directory t)
          (unless (executable-find "unzip")
            (user-error "The unzip command is required to install Codex Pets zips"))
          (unless (zerop (call-process "unzip" nil nil nil "-q" "-o" zip-file
                                       "-d" target-directory))
            (agent-shell-pet--safe-delete-directory install-root target-directory)
            (user-error "Failed to unzip pet package"))
          (unless (agent-shell-pet--load-pet target-directory)
            (agent-shell-pet--safe-delete-directory install-root target-directory)
            (user-error "Downloaded pet did not validate as a Codex-compatible atlas"))
          (message "Installed pet %s into %s" pet-id install-root)
          target-directory)
      (when (file-exists-p zip-file)
        (delete-file zip-file)))))

(defun agent-shell-pet--state-durations (state)
  "Return frame durations for STATE."
  (plist-get (alist-get state agent-shell-pet--state-specs) :durations))

(defun agent-shell-pet--state-row (state)
  "Return atlas row for STATE."
  (plist-get (alist-get state agent-shell-pet--state-specs) :row))

(defun agent-shell-pet--cache-key (pet)
  "Return cache key for PET."
  (secure-hash 'sha1
               (format "%s:%s:%s"
                       (agent-shell-pet-id pet)
                       (agent-shell-pet-spritesheet-path pet)
                       (file-attribute-modification-time
                        (file-attributes (agent-shell-pet-spritesheet-path pet))))))

(defun agent-shell-pet--frame-path (pet state index)
  "Return cached frame path for PET STATE INDEX."
  (expand-file-name
   (format "%s/%s/%s-%02d.png"
           (agent-shell-pet--cache-key pet)
           (symbol-name state)
           (symbol-name state)
           index)
   agent-shell-pet-cache-directory))

(defun agent-shell-pet--extract-frame (pet state index)
  "Extract PET STATE INDEX to the frame cache."
  (let* ((row (agent-shell-pet--state-row state))
         (x (* index agent-shell-pet--cell-width))
         (y (* row agent-shell-pet--cell-height))
         (output (agent-shell-pet--frame-path pet state index)))
    (unless (file-exists-p output)
      (unless (executable-find agent-shell-pet-frame-extractor-command)
        (user-error "ImageMagick command not found: %s"
                    agent-shell-pet-frame-extractor-command))
      (make-directory (file-name-directory output) t)
      (unless (zerop (call-process
                      agent-shell-pet-frame-extractor-command nil nil nil
                      (agent-shell-pet-spritesheet-path pet)
                      "-crop"
                      (format "%dx%d+%d+%d"
                              agent-shell-pet--cell-width
                              agent-shell-pet--cell-height
                              x y)
                      "+repage"
                      output))
        (delete-file output)
        (user-error "Failed to extract pet frame with %s"
                    agent-shell-pet-frame-extractor-command)))
    output))

(defun agent-shell-pet--ensure-frame-cache (pet)
  "Ensure all configured PET frames are extracted."
  (dolist (state agent-shell-pet-enabled-states)
    (let ((durations (agent-shell-pet--state-durations state)))
      (cl-loop for index below (length durations)
               do (agent-shell-pet--extract-frame pet state index)))))

(defun agent-shell-pet--renderer-show (runtime)
  "Show RUNTIME using the configured renderer."
  (pcase (agent-shell-pet--runtime-renderer runtime)
    ('child-frame (agent-shell-pet--child-frame-show runtime))
    ('macos-native (agent-shell-pet--macos-show runtime))
    ('global nil)
    (_ (user-error "Unknown pet renderer: %S"
                   (agent-shell-pet--runtime-renderer runtime)))))

(defun agent-shell-pet--renderer-hide (runtime)
  "Hide RUNTIME renderer."
  (pcase (agent-shell-pet--runtime-renderer runtime)
    ('child-frame (agent-shell-pet--child-frame-hide runtime))
    ('macos-native (agent-shell-pet--macos-hide runtime))
    ('global nil)))

(defun agent-shell-pet--renderer-set-frame (runtime frame-file)
  "Render FRAME-FILE for RUNTIME."
  (pcase (agent-shell-pet--runtime-renderer runtime)
    ('child-frame (agent-shell-pet--child-frame-set-frame runtime frame-file))
    ('macos-native (agent-shell-pet--macos-set-frame runtime frame-file))
    ('global nil)))

(defun agent-shell-pet--display-runtime-p (runtime)
  "Return non-nil when RUNTIME owns a visible renderer."
  (or (not (eq agent-shell-pet-scope 'global))
      (agent-shell-pet--runtime-global-display-p runtime)))

(defun agent-shell-pet--size-scale ()
  "Return the numeric scale for `agent-shell-pet-size'."
  (pcase agent-shell-pet-size
    ('small 0.55)
    ('medium 0.75)
    (_ 1.0)))

(defun agent-shell-pet--effective-scale ()
  "Return the effective pet scale."
  (* agent-shell-pet-scale (agent-shell-pet--size-scale)))

(defun agent-shell-pet--child-frame-size (&optional runtime)
  "Return child-frame pixel size as (WIDTH . HEIGHT) for RUNTIME."
  (let ((scale (agent-shell-pet--effective-scale)))
    (cons (max 1 (round (* agent-shell-pet--cell-width scale)))
          (+ (max 1 (round (* agent-shell-pet--cell-height scale)))
             (if (agent-shell-pet--speech-bubble-visible-p runtime)
                 agent-shell-pet-speech-bubble-height
               0)))))

(defun agent-shell-pet--child-image-size ()
  "Return child-frame sprite image size as (WIDTH . HEIGHT)."
  (let ((scale (agent-shell-pet--effective-scale)))
    (cons (max 1 (round (* agent-shell-pet--cell-width scale)))
          (max 1 (round (* agent-shell-pet--cell-height scale))))))

(defun agent-shell-pet--speech-bubble-visible-p (&optional runtime)
  "Return non-nil when RUNTIME should show a child-frame speech bubble."
  (and agent-shell-pet-show-speech-bubble
       (or (not runtime)
           agent-shell-pet-show-idle-speech-bubble
           (not (eq (agent-shell-pet--runtime-state runtime) 'idle)))
       (or (not runtime)
           (not (string-empty-p
                 (or (agent-shell-pet--runtime-status-text runtime) ""))))))

(defun agent-shell-pet--child-frame-position (&optional runtime)
  "Return child-frame position as (LEFT . TOP) for RUNTIME."
  (let* ((size (agent-shell-pet--child-frame-size runtime))
         (width (car size))
         (height (cdr size))
         (frame-width (frame-pixel-width))
         (frame-height (frame-pixel-height)))
    (pcase agent-shell-pet-position
      ('bottom-left (cons agent-shell-pet-margin-x
                          (- frame-height height agent-shell-pet-margin-y)))
      ('top-right (cons (- frame-width width agent-shell-pet-margin-x)
                        agent-shell-pet-margin-y))
      ('top-left (cons agent-shell-pet-margin-x agent-shell-pet-margin-y))
      (_ (cons (- frame-width width agent-shell-pet-margin-x)
               (- frame-height height agent-shell-pet-margin-y))))))

(defun agent-shell-pet--child-buffer (runtime)
  "Return RUNTIME's child-frame pet buffer."
  (let* ((shell-buffer (agent-shell-pet--runtime-shell-buffer runtime))
         (buffer (or (agent-shell-pet--runtime-child-buffer runtime)
                     (get-buffer-create
                      (format " *agent-shell-pet:%s*"
                              (buffer-name shell-buffer))))))
    (setf (agent-shell-pet--runtime-child-buffer runtime) buffer)
    (with-current-buffer buffer
      (setq-local mode-line-format nil)
      (setq-local cursor-type nil)
      (setq-local truncate-lines t)
      (setq-local inhibit-read-only t))
    buffer))

(defun agent-shell-pet--child-frame-show (runtime)
  "Show the child-frame renderer for RUNTIME."
  (unless (display-graphic-p)
    (user-error "agent-shell-pet child-frame renderer requires a graphical Emacs frame"))
  (let* ((size (agent-shell-pet--child-frame-size runtime))
         (pos (agent-shell-pet--child-frame-position runtime))
         (params `((name . "agent-shell-pet")
                   (parent-frame . ,(selected-frame))
                   (minibuffer . nil)
                   (undecorated . t)
                   (no-accept-focus . t)
                   (skip-taskbar . t)
                   (no-other-frame . t)
                   (visibility . nil)
                   (left . ,(car pos))
                   (top . ,(cdr pos))
                   (width . ,(car size))
                   (height . ,(cdr size))
                   (user-position . t)
                   (drag-internal-border . t)
                   (internal-border-width . 0)
                   (child-frame-border-width . 0)
                   (vertical-scroll-bars . nil)
                   (horizontal-scroll-bars . nil)
                   (menu-bar-lines . 0)
                   (tool-bar-lines . 0)
                   (tab-bar-lines . 0)
                   (unsplittable . t))))
    (if (frame-live-p (agent-shell-pet--runtime-child-frame runtime))
        (modify-frame-parameters (agent-shell-pet--runtime-child-frame runtime)
                                 params)
      (setf (agent-shell-pet--runtime-child-frame runtime)
            (make-frame params))
      (set-window-buffer
       (frame-root-window (agent-shell-pet--runtime-child-frame runtime))
       (agent-shell-pet--child-buffer runtime)))
    (make-frame-visible (agent-shell-pet--runtime-child-frame runtime))))

(defun agent-shell-pet--child-frame-hide (runtime)
  "Hide the child-frame renderer for RUNTIME."
  (condition-case nil
      (progn
        (when (frame-live-p (agent-shell-pet--runtime-child-frame runtime))
          (delete-frame (agent-shell-pet--runtime-child-frame runtime) t)
          (setf (agent-shell-pet--runtime-child-frame runtime) nil))
        (when (buffer-live-p (agent-shell-pet--runtime-child-buffer runtime))
          (kill-buffer (agent-shell-pet--runtime-child-buffer runtime))
          (setf (agent-shell-pet--runtime-child-buffer runtime) nil)))
    (error nil)))

(defun agent-shell-pet--child-frame-set-frame (runtime frame-file)
  "Render FRAME-FILE in the child-frame renderer."
  (when (frame-live-p (agent-shell-pet--runtime-child-frame runtime))
    (agent-shell-pet--child-frame-show runtime))
  (let ((buffer (agent-shell-pet--child-buffer runtime))
        (size (agent-shell-pet--child-image-size)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (when (agent-shell-pet--speech-bubble-visible-p runtime)
          (let* ((text (or (agent-shell-pet--runtime-status-text runtime) ""))
                 (width (max 1 (window-width (frame-root-window
                                              (agent-shell-pet--runtime-child-frame
                                               runtime)))))
                 (label (truncate-string-to-width text width nil nil "...")))
            (insert
             (propertize label
                         'face 'agent-shell-pet-speech-bubble))
            (insert "\n")))
        (insert-image (create-image frame-file 'png nil
                                    :width (car size)
                                    :height (cdr size)))))))

(defun agent-shell-pet--macos-helper-live-p (runtime)
  "Return non-nil when RUNTIME has a live macOS helper process."
  (let ((process (agent-shell-pet--runtime-native-process runtime)))
    (and (processp process)
         (process-live-p process))))

(defun agent-shell-pet--macos-helper-build-dir ()
  "Return the directory containing the macOS helper Makefile."
  (file-name-directory agent-shell-pet-macos-helper-path))

(defun agent-shell-pet--macos-helper-buildable-p ()
  "Return non-nil when the macOS helper can be built in-place.
True when the build directory and its Makefile exist on disk and a
`make' executable is available on PATH."
  (let ((build-dir (agent-shell-pet--macos-helper-build-dir)))
    (and (file-directory-p build-dir)
         (file-readable-p (expand-file-name "Makefile" build-dir))
         (executable-find "make"))))

(defun agent-shell-pet--macos-build-helper-sync ()
  "Build the macOS helper synchronously.
Build output is collected in `*agent-shell-pet build*'; the buffer is
displayed on failure.  Returns non-nil when the helper executable
exists after the build."
  (let* ((build-dir (agent-shell-pet--macos-helper-build-dir))
         (buffer (get-buffer-create "*agent-shell-pet build*"))
         exit)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "$ make -C %s\n\n" build-dir))))
    (message "agent-shell-pet: building macOS helper in %s ..."
             (abbreviate-file-name build-dir))
    (let ((default-directory build-dir))
      (setq exit (call-process "make" nil buffer t)))
    (cond
     ((and (eq exit 0)
           (file-executable-p agent-shell-pet-macos-helper-path))
      (message "agent-shell-pet: macOS helper built at %s"
               (abbreviate-file-name agent-shell-pet-macos-helper-path))
      t)
     (t
      (display-buffer buffer)
      (message "agent-shell-pet: build failed (exit %S); see *agent-shell-pet build*"
               exit)
      nil))))

(defun agent-shell-pet--macos-maybe-prompt-build ()
  "Offer to build the macOS helper when it is missing.
Returns non-nil once the helper is executable.  No-op when not running
on macOS, when the helper already exists, or when the build directory
is not present (e.g. an installation that stripped the renderer
sources)."
  (cond
   ((file-executable-p agent-shell-pet-macos-helper-path) t)
   ((not (eq system-type 'darwin)) nil)
   ((not (agent-shell-pet--macos-helper-buildable-p)) nil)
   ((y-or-n-p
     (format "agent-shell-pet: macOS helper is not built. Build it now (make -C %s)? "
             (abbreviate-file-name (agent-shell-pet--macos-helper-build-dir))))
    (agent-shell-pet--macos-build-helper-sync))
   (t nil)))

(defun agent-shell-pet--macos-ensure-process (runtime)
  "Ensure RUNTIME has a live macOS renderer helper."
  (unless (eq system-type 'darwin)
    (user-error "The macOS native renderer only works on macOS"))
  (unless (file-executable-p agent-shell-pet-macos-helper-path)
    (unless (agent-shell-pet--macos-maybe-prompt-build)
      (user-error "macOS pet helper is not executable. Build it with: make -C %s"
                  (agent-shell-pet--macos-helper-build-dir))))
  (unless (agent-shell-pet--macos-helper-live-p runtime)
    (let* ((shell-buffer (agent-shell-pet--runtime-shell-buffer runtime))
           (process-name (if (buffer-live-p shell-buffer)
                             (buffer-name shell-buffer)
                           "global"))
           (process
           (make-process
            :name (format "agent-shell-pet-macos:%s"
                          process-name)
            :buffer nil
            :command (list agent-shell-pet-macos-helper-path)
            :connection-type 'pipe
            :noquery t
            :sentinel (lambda (process _event)
                        (when (memq (process-status process) '(exit signal))
                          (set-process-query-on-exit-flag process nil))))))
      (setf (agent-shell-pet--runtime-native-process runtime) process)))
  (agent-shell-pet--runtime-native-process runtime))

(defun agent-shell-pet--macos-send (runtime payload)
  "Send PAYLOAD to RUNTIME's macOS helper."
  (let ((process (agent-shell-pet--macos-ensure-process runtime)))
    (process-send-string
     process
     (concat (json-encode payload) "\n"))))

(defun agent-shell-pet--macos-position-name ()
  "Return current pet position as a JSON-friendly string."
  (pcase agent-shell-pet-position
    ('bottom-left "bottom-left")
    ('top-left "top-left")
    ('top-right "top-right")
    (_ "bottom-right")))

(defun agent-shell-pet--default-card-title (runtime)
  "Return a compact notification card title for RUNTIME."
  (let* ((buffer (agent-shell-pet--runtime-shell-buffer runtime))
         (name (if (buffer-live-p buffer)
                   (buffer-name buffer)
                 "Agent"))
         (name (or name "Agent"))
         (name (replace-regexp-in-string "\\`[ *]*" "" name))
         (name (replace-regexp-in-string "[ *]*\\'" "" name)))
    (truncate-string-to-width name 42 nil nil "...")))

(defun agent-shell-pet--macos-card-title (runtime)
  "Return the native macOS notification card title for RUNTIME."
  (when agent-shell-pet-macos-card-title-function
    (funcall agent-shell-pet-macos-card-title-function runtime)))

(defun agent-shell-pet--macos-card-status (runtime)
  "Return the native macOS notification card status for RUNTIME."
  (cond
   ((eq (agent-shell-pet--runtime-state runtime) 'failed) "error")
   ((and (eq (agent-shell-pet--runtime-state runtime) 'review)
         (member (agent-shell-pet--runtime-status-text runtime)
                 '("Done" "Turn complete")))
    "done")
   (t "thinking")))

(defun agent-shell-pet--notification-card (runtime)
  "Return a JSON-friendly notification card for RUNTIME."
  `((title . ,(or (agent-shell-pet--macos-card-title runtime) ""))
    (body . ,(or (agent-shell-pet--runtime-status-text runtime) ""))
    (cardStatus . ,(agent-shell-pet--macos-card-status runtime))))

(defun agent-shell-pet--macos-show (runtime)
  "Show RUNTIME using the macOS native helper."
  (agent-shell-pet--macos-send
   runtime
   `((type . "show")
     (scale . ,(agent-shell-pet--effective-scale))
     (marginX . ,agent-shell-pet-margin-x)
     (marginY . ,agent-shell-pet-margin-y)
     (position . ,(agent-shell-pet--macos-position-name)))))

(defun agent-shell-pet--macos-hide (runtime)
  "Hide and stop RUNTIME's macOS native helper."
  (when (agent-shell-pet--macos-helper-live-p runtime)
    (ignore-errors
      (agent-shell-pet--macos-send runtime '((type . "quit"))))
    (delete-process (agent-shell-pet--runtime-native-process runtime))
    (setf (agent-shell-pet--runtime-native-process runtime) nil)))

(defun agent-shell-pet--macos-set-frame (runtime frame-file)
  "Render FRAME-FILE for RUNTIME using the macOS native helper."
  (let ((notifications (and (agent-shell-pet--runtime-global-display-p runtime)
                            (agent-shell-pet--global-notification-cards))))
    (agent-shell-pet--macos-send
     runtime
     `((type . "frame")
       (path . ,frame-file)
       (title . ,(or (agent-shell-pet--macos-card-title runtime) ""))
       (body . ,(or (agent-shell-pet--runtime-status-text runtime) ""))
       (cardStatus . ,(agent-shell-pet--macos-card-status runtime))
       (cardTheme . ,(symbol-name agent-shell-pet-speech-bubble-theme))
       (showBubble . ,(and (agent-shell-pet--speech-bubble-visible-p runtime) t))
       (notifications . ,(or notifications []))))))

(defun agent-shell-pet--current-frame-path (runtime)
  "Return the image path for RUNTIME's current frame."
  (unless (agent-shell-pet--runtime-live-p runtime)
    (error "Stale or invalid agent-shell-pet runtime"))
  (agent-shell-pet--extract-frame
   (agent-shell-pet--runtime-pet runtime)
   (agent-shell-pet--runtime-state runtime)
   (agent-shell-pet--runtime-frame-index runtime)))

(defun agent-shell-pet--cancel-animation (runtime)
  "Cancel RUNTIME animation timer."
  (when-let ((timer (and (agent-shell-pet--runtime-p runtime)
                         (agent-shell-pet--runtime-timer runtime))))
    (when (timerp timer)
      (cancel-timer timer))
    (setf (agent-shell-pet--runtime-timer runtime) nil)))

(defun agent-shell-pet--tick (runtime)
  "Advance RUNTIME animation by one frame."
  (when (agent-shell-pet--runtime-live-p runtime)
    (let* ((durations (agent-shell-pet--state-durations
                       (agent-shell-pet--runtime-state runtime)))
           (next (mod (1+ (agent-shell-pet--runtime-frame-index runtime))
                      (length durations))))
      (setf (agent-shell-pet--runtime-frame-index runtime) next)
      (agent-shell-pet--renderer-set-frame
       runtime
       (agent-shell-pet--current-frame-path runtime))
      (agent-shell-pet--schedule-next-frame runtime))))

(defun agent-shell-pet--schedule-next-frame (runtime)
  "Schedule RUNTIME's next animation frame."
  (when (agent-shell-pet--runtime-live-p runtime)
    (agent-shell-pet--cancel-animation runtime)
    (let* ((durations (agent-shell-pet--state-durations
                       (agent-shell-pet--runtime-state runtime)))
           (index (min (agent-shell-pet--runtime-frame-index runtime)
                       (1- (length durations))))
           (delay (/ (float (nth index durations)) 1000.0)))
      (setf (agent-shell-pet--runtime-timer runtime)
            (run-at-time delay nil #'agent-shell-pet--tick runtime)))))

(defun agent-shell-pet--state-default-text (state)
  "Return default status text for STATE."
  (pcase state
    ('idle agent-shell-pet-idle-status-text)
    ('running agent-shell-pet-thinking-status-text)
    ('running-right agent-shell-pet-thinking-status-text)
    ('running-left agent-shell-pet-thinking-status-text)
    ('waiting "Need you")
    ('review nil)
    ('failed "Stuck")
    ('waving "Hi")
    ('jumping "Yep")
    (_ (capitalize (symbol-name state)))))

(defun agent-shell-pet--clean-status-text (text)
  "Return compact status TEXT."
  (when text
    (string-trim
     (replace-regexp-in-string "[\n\t ]+" " " (substring-no-properties text)))))

(defun agent-shell-pet--short-tool-title (text)
  "Return a compact version of tool title TEXT."
  (when-let ((clean (agent-shell-pet--clean-status-text text)))
    (let* ((clean (replace-regexp-in-string "\\`\\[[^]]+\\][ \t]*" "" clean))
           (clean (replace-regexp-in-string "\\`Bash[ \t]*" "" clean))
           (clean (replace-regexp-in-string "\\`Read[ \t]+" "" clean))
           (clean (replace-regexp-in-string "\\`Edit[ \t]+" "" clean)))
      (truncate-string-to-width clean 34 nil nil "..."))))

(defun agent-shell-pet--kind-phrase (kind)
  "Return a short pet phrase for tool KIND."
  (cond
   ((member kind '("read" read)) "Reading")
   ((member kind '("edit" edit)) "Editing")
   ((member kind '("execute" execute)) "Running")
   ((member kind '("search" search)) "Searching")
   (t "Working")))

(defun agent-shell-pet--tool-call-text (tool-call)
  "Return status text for TOOL-CALL."
  (let* ((status (alist-get :status tool-call))
         (kind (alist-get :kind tool-call))
         (title (or (alist-get :title tool-call)
                    (alist-get :description tool-call)
                    (alist-get :command tool-call)))
         (short-title (agent-shell-pet--short-tool-title title))
         (phrase (agent-shell-pet--kind-phrase kind)))
    (if (eq agent-shell-pet-speech-style 'technical)
        (cond
         ((member status '("failed" failed))
          (if short-title (format "Blocked: %s" short-title) "Blocked"))
         ((member status '("completed" completed))
          (if short-title (format "Done: %s" short-title) "Done"))
         (short-title short-title)
         (t phrase))
      (cond
       ((member status '("failed" failed)) "I'm stuck")
       ((member status '("completed" completed))
        (if agent-shell-pet-chatty "Done" agent-shell-pet-thinking-status-text))
       (short-title (format "%s: %s" phrase short-title))
       (t phrase)))))

(defun agent-shell-pet--set-state (runtime state &optional status-text)
  "Set RUNTIME animation STATE with optional STATUS-TEXT."
  (when (and (agent-shell-pet--runtime-p runtime)
             (alist-get state agent-shell-pet--state-specs))
    (unless (natnump (agent-shell-pet--runtime-frame-index runtime))
      (setf (agent-shell-pet--runtime-frame-index runtime) 0))
    (unless (eq (agent-shell-pet--runtime-state runtime) state)
      (setf (agent-shell-pet--runtime-state runtime) state)
      (setf (agent-shell-pet--runtime-frame-index runtime) 0))
    (setf (agent-shell-pet--runtime-status-text runtime)
          (or (agent-shell-pet--clean-status-text status-text)
              (agent-shell-pet--state-default-text state)))
    (setf (agent-shell-pet--runtime-updated-at runtime) (current-time))
    (if (agent-shell-pet--display-runtime-p runtime)
        (progn
          (agent-shell-pet--renderer-set-frame
           runtime
           (agent-shell-pet--current-frame-path runtime))
          (agent-shell-pet--schedule-next-frame runtime))
      (agent-shell-pet--global-refresh))))

(defun agent-shell-pet--cancel-transient (runtime)
  "Cancel RUNTIME transient state timer."
  (when-let ((timer (and (agent-shell-pet--runtime-p runtime)
                         (agent-shell-pet--runtime-transient-timer runtime))))
    (when (timerp timer)
      (cancel-timer timer))
    (setf (agent-shell-pet--runtime-transient-timer runtime) nil)))

(defun agent-shell-pet--transient-active-p (runtime)
  "Return non-nil when RUNTIME is showing a protected transient state."
  (and (agent-shell-pet--runtime-p runtime)
       (agent-shell-pet--runtime-transient-timer runtime)))

(defun agent-shell-pet--set-transient-state (runtime state seconds)
  "Set RUNTIME to STATE for SECONDS, then return to idle."
  (agent-shell-pet--cancel-transient runtime)
  (let ((previous-state (agent-shell-pet--runtime-state runtime))
        (previous-text (agent-shell-pet--runtime-status-text runtime)))
    (agent-shell-pet--set-state runtime state)
    (setf (agent-shell-pet--runtime-transient-timer runtime)
          (run-at-time seconds nil
                       (lambda (runtime)
                         (when runtime
                           (setf (agent-shell-pet--runtime-transient-timer runtime) nil)
                           (agent-shell-pet--set-state
                            runtime
                            (or previous-state 'idle)
                            previous-text)))
                       runtime))))

(defun agent-shell-pet--set-state-then-idle (runtime state status-text seconds)
  "Set RUNTIME to STATE with STATUS-TEXT for SECONDS, then return to idle."
  (agent-shell-pet--cancel-transient runtime)
  (agent-shell-pet--set-state runtime state status-text)
  (setf (agent-shell-pet--runtime-transient-timer runtime)
        (run-at-time seconds nil
                     (lambda (runtime)
                       (when (agent-shell-pet--runtime-live-p runtime)
                         (setf (agent-shell-pet--runtime-transient-timer
                                runtime)
                               nil)
                         (agent-shell-pet--set-state
                          runtime
                          'idle
                          agent-shell-pet-idle-status-text)))
                     runtime)))

(defun agent-shell-pet--tool-call-state (tool-call)
  "Return pet state for TOOL-CALL."
  (let ((status (alist-get :status tool-call))
        (kind (alist-get :kind tool-call)))
    (cond
     ((member status '("failed" failed)) 'failed)
     ((member status '("completed" completed)) 'review)
     ((member kind '("read" read "edit" edit)) 'review)
     (t 'running))))

(defun agent-shell-pet--state-rank (state)
  "Return urgency rank for STATE in the global pet."
  (pcase state
    ('failed 50)
    ('waiting 40)
    ('running 30)
    ('running-right 30)
    ('running-left 30)
    ('review 20)
    (_ 0)))

(defun agent-shell-pet--runtime-dismissed-p (runtime)
  "Return non-nil when RUNTIME's current notification has been dismissed."
  (let ((updated-at (agent-shell-pet--runtime-updated-at runtime))
        (dismissed-at (agent-shell-pet--runtime-dismissed-at runtime)))
    (and updated-at
         dismissed-at
         (not (time-less-p dismissed-at updated-at)))))

(defun agent-shell-pet--global-prune-runtimes ()
  "Remove dead runtimes from the global runtime registry."
  (maphash
   (lambda (buffer runtime)
     (unless (and (buffer-live-p buffer)
                  (agent-shell-pet--runtime-p runtime))
       (remhash buffer agent-shell-pet--global-runtimes)))
   agent-shell-pet--global-runtimes))

(defun agent-shell-pet--global-runtime-list ()
  "Return live runtimes contributing to the global pet."
  (agent-shell-pet--global-prune-runtimes)
  (let (runtimes)
    (maphash (lambda (_buffer runtime)
               (when (and (agent-shell-pet--runtime-live-p runtime)
                          (not (eq (agent-shell-pet--runtime-state runtime) 'idle))
                          (not (agent-shell-pet--runtime-dismissed-p runtime)))
                 (push runtime runtimes)))
             agent-shell-pet--global-runtimes)
    (sort runtimes
          (lambda (left right)
            (let ((left-rank (agent-shell-pet--state-rank
                              (agent-shell-pet--runtime-state left)))
                  (right-rank (agent-shell-pet--state-rank
                               (agent-shell-pet--runtime-state right))))
              (if (= left-rank right-rank)
                  (time-less-p
                   (or (agent-shell-pet--runtime-updated-at right)
                       '(0 0 0 0))
                   (or (agent-shell-pet--runtime-updated-at left)
                       '(0 0 0 0)))
                (> left-rank right-rank)))))))

(defun agent-shell-pet--global-notification-runtimes ()
  "Return runtimes that should appear as stacked global notifications."
  (seq-take (seq-filter
             (lambda (runtime)
               (and (not (eq (agent-shell-pet--runtime-state runtime) 'idle))
                    (not (string-empty-p
                          (or (agent-shell-pet--runtime-status-text runtime) "")))))
             (agent-shell-pet--global-runtime-list))
            (max 0 agent-shell-pet-max-notifications)))

(defun agent-shell-pet--global-notification-cards ()
  "Return stacked notification cards for the global renderer."
  (mapcar #'agent-shell-pet--notification-card
          (agent-shell-pet--global-notification-runtimes)))

(defun agent-shell-pet--global-top-runtime ()
  "Return the runtime that should drive the global pet animation."
  (car (agent-shell-pet--global-runtime-list)))

(defun agent-shell-pet--global-refresh ()
  "Refresh the global pet display from all registered runtimes."
  (when (and (eq agent-shell-pet-scope 'global)
             (not agent-shell-pet--global-display-suppressed)
             (agent-shell-pet--runtime-live-p agent-shell-pet--global-runtime))
    (let* ((top (agent-shell-pet--global-top-runtime))
           (state (if top
                      (agent-shell-pet--runtime-state top)
                    'idle))
           (status-text (if top
                            (agent-shell-pet--runtime-status-text top)
                          agent-shell-pet-idle-status-text)))
      (unless (eq (agent-shell-pet--runtime-state agent-shell-pet--global-runtime)
                  state)
        (setf (agent-shell-pet--runtime-frame-index agent-shell-pet--global-runtime)
              0))
      (setf (agent-shell-pet--runtime-state agent-shell-pet--global-runtime) state)
      (setf (agent-shell-pet--runtime-status-text agent-shell-pet--global-runtime)
            status-text)
      (agent-shell-pet--renderer-set-frame
       agent-shell-pet--global-runtime
       (agent-shell-pet--current-frame-path agent-shell-pet--global-runtime))
      (agent-shell-pet--schedule-next-frame agent-shell-pet--global-runtime))))

(defun agent-shell-pet--turn-success-p (data)
  "Return non-nil when turn-complete DATA represents a successful turn."
  (member (or (alist-get :stop-reason data)
              (alist-get 'stop-reason data)
              (alist-get 'stopReason data)
              (alist-get :stopReason data))
          '("end_turn" end_turn)))

(defun agent-shell-pet--handle-event (runtime event)
  "Update RUNTIME from agent-shell EVENT."
  (let ((name (alist-get :event event))
        (data (alist-get :data event)))
    (pcase name
      ((or 'init-started 'init-client 'init-subscriptions 'init-handshake)
       (agent-shell-pet--cancel-transient runtime)
       (agent-shell-pet--set-state runtime 'running "Waking up"))
      ('input-submitted
       (agent-shell-pet--cancel-transient runtime)
       (agent-shell-pet--set-state runtime 'running
                                   agent-shell-pet-thinking-status-text))
      ((or 'prompt-ready 'idle)
       (unless (agent-shell-pet--transient-active-p runtime)
         (agent-shell-pet--set-state runtime 'idle agent-shell-pet-idle-status-text)))
      ('permission-request
       (agent-shell-pet--cancel-transient runtime)
       (agent-shell-pet--set-state runtime 'waiting "Need your OK"))
      ('tool-call-update
       (agent-shell-pet--cancel-transient runtime)
       (let ((tool-call (alist-get :tool-call data)))
         (agent-shell-pet--set-state
          runtime
          (agent-shell-pet--tool-call-state tool-call)
          (agent-shell-pet--tool-call-text tool-call))))
      ('turn-complete
       (if (agent-shell-pet--turn-success-p data)
           (agent-shell-pet--set-state-then-idle
            runtime
            'review
            "Turn complete"
            agent-shell-pet-completion-display-seconds)
         (agent-shell-pet--set-state runtime 'failed
                                     "I hit a snag")))
      ('error
       (agent-shell-pet--cancel-transient runtime)
       (agent-shell-pet--set-state runtime 'failed "Something broke"))
      ('clean-up
       (agent-shell-pet-mode -1)))))

(defun agent-shell-pet--subscribe (runtime)
  "Subscribe RUNTIME to agent-shell events."
  (let ((shell-buffer (agent-shell-pet--runtime-shell-buffer runtime)))
    (with-current-buffer shell-buffer
      (setf (agent-shell-pet--runtime-subscriptions runtime)
            (list
             (agent-shell-subscribe-to
              :shell-buffer shell-buffer
              :on-event (lambda (event)
                          (agent-shell-pet--handle-event runtime event))))))))

(defun agent-shell-pet--unsubscribe (runtime)
  "Unsubscribe RUNTIME from agent-shell events."
  (when-let ((shell-buffer (agent-shell-pet--runtime-shell-buffer runtime)))
    (when (buffer-live-p shell-buffer)
      (with-current-buffer shell-buffer
        (let ((subscriptions (agent-shell-pet--runtime-subscriptions runtime)))
          (when (listp subscriptions)
            (dolist (subscription subscriptions)
              (ignore-errors
                (agent-shell-unsubscribe :subscription subscription)))))))))

(defun agent-shell-pet--global-ensure-display (pet shell-buffer)
  "Ensure the global display runtime exists for PET and SHELL-BUFFER."
  (unless (agent-shell-pet--runtime-live-p agent-shell-pet--global-runtime)
    (setq agent-shell-pet--global-runtime
          (agent-shell-pet--make-runtime
           :pet pet
           :shell-buffer shell-buffer
           :renderer agent-shell-pet-renderer
           :state 'idle
           :status-text agent-shell-pet-idle-status-text
           :frame-index 0
           :global-display-p t
           :updated-at (current-time)))
    (agent-shell-pet--renderer-show agent-shell-pet--global-runtime)
    (agent-shell-pet--renderer-set-frame
     agent-shell-pet--global-runtime
     (agent-shell-pet--current-frame-path agent-shell-pet--global-runtime))
    (agent-shell-pet--schedule-next-frame agent-shell-pet--global-runtime)))

(defun agent-shell-pet--global-register (runtime)
  "Register RUNTIME with the global pet display."
  (puthash (agent-shell-pet--runtime-shell-buffer runtime)
           runtime
           agent-shell-pet--global-runtimes)
  (agent-shell-pet--global-refresh))

(defun agent-shell-pet--global-unregister (runtime)
  "Remove RUNTIME from the global pet display."
  (when (agent-shell-pet--runtime-p runtime)
    (remhash (agent-shell-pet--runtime-shell-buffer runtime)
             agent-shell-pet--global-runtimes)
    (agent-shell-pet--global-refresh)))

(defun agent-shell-pet--global-stop-display ()
  "Stop the global pet display when no buffers remain."
  (agent-shell-pet--global-prune-runtimes)
  (when (and (zerop (hash-table-count agent-shell-pet--global-runtimes))
             (agent-shell-pet--runtime-p agent-shell-pet--global-runtime))
    (agent-shell-pet--cancel-animation agent-shell-pet--global-runtime)
    (agent-shell-pet--renderer-hide agent-shell-pet--global-runtime)
    (setq agent-shell-pet--global-runtime nil)
    (setq agent-shell-pet--global-display-suppressed nil)))

(defun agent-shell-pet--dismiss-runtime-notification (runtime)
  "Dismiss RUNTIME's current global notification."
  (when (and (agent-shell-pet--runtime-p runtime)
             (agent-shell-pet--runtime-updated-at runtime))
    (setf (agent-shell-pet--runtime-dismissed-at runtime)
          (agent-shell-pet--runtime-updated-at runtime))
    (agent-shell-pet--global-refresh)))

(defun agent-shell-pet--maybe-dismiss-selected-notification ()
  "Dismiss the selected agent-shell buffer's current global notification."
  (when (and agent-shell-pet-dismiss-notification-on-buffer-visit
             (eq agent-shell-pet-scope 'global)
             global-agent-shell-pet-mode)
    (when-let* ((buffer (window-buffer (selected-window)))
                (runtime (gethash buffer agent-shell-pet--global-runtimes))
                ((not (eq (agent-shell-pet--runtime-state runtime) 'idle)))
                ((not (agent-shell-pet--runtime-dismissed-p runtime))))
      (agent-shell-pet--dismiss-runtime-notification runtime))))

;;;###autoload
(define-minor-mode agent-shell-pet-mode
  "Display an animated pet for the current agent-shell buffer."
  :lighter " Pet"
  :group 'agent-shell-pet
  (if agent-shell-pet-mode
      (progn
        (unless (derived-mode-p 'agent-shell-mode)
          (setq agent-shell-pet-mode nil)
          (user-error "agent-shell-pet-mode must be enabled in an agent-shell buffer"))
        ;; Idempotent enable.  `define-minor-mode' always re-runs the body
        ;; on `(MODE 1)' even when MODE is already on, and
        ;; `global-agent-shell-pet-mode' propagates this by walking every
        ;; agent-shell buffer on every toggle.  Without this guard a user
        ;; re-evaluating their init file would overwrite the buffer-local
        ;; runtime, orphaning its renderer (an extra macOS helper process,
        ;; an extra child frame), animation timer, and event subscriptions
        ;; — visible as a second pet on screen with no way to dismiss the
        ;; first.  Use `agent-shell-pet-reset' to forcibly rebuild.
        (unless (and agent-shell-pet--runtime
                     (agent-shell-pet--runtime-live-p agent-shell-pet--runtime))
          (require 'agent-shell)
          (let ((pet (agent-shell-pet--select-pet)))
            (agent-shell-pet--ensure-frame-cache pet)
            (setq agent-shell-pet--runtime
                  (agent-shell-pet--make-runtime
                   :pet pet
                   :shell-buffer (current-buffer)
                   :renderer (if (eq agent-shell-pet-scope 'global)
                                 'global
                               agent-shell-pet-renderer)
                   :state 'idle
                   :status-text agent-shell-pet-idle-status-text
                   :frame-index 0
                   :updated-at (current-time)))
            (if (eq agent-shell-pet-scope 'global)
                (progn
                  (agent-shell-pet--global-ensure-display
                   pet
                   (current-buffer))
                  (agent-shell-pet--global-register agent-shell-pet--runtime))
              (agent-shell-pet--renderer-show agent-shell-pet--runtime)
              (agent-shell-pet--renderer-set-frame
               agent-shell-pet--runtime
               (agent-shell-pet--current-frame-path agent-shell-pet--runtime))
              (agent-shell-pet--schedule-next-frame agent-shell-pet--runtime))
            (agent-shell-pet--subscribe agent-shell-pet--runtime))))
    (when agent-shell-pet--runtime
      (when (eq agent-shell-pet-scope 'global)
        (agent-shell-pet--global-unregister agent-shell-pet--runtime))
      (agent-shell-pet--unsubscribe agent-shell-pet--runtime)
      (agent-shell-pet--cancel-animation agent-shell-pet--runtime)
      (when-let ((timer (agent-shell-pet--runtime-transient-timer
                         agent-shell-pet--runtime)))
        (when (timerp timer)
          (cancel-timer timer)))
      (unless (eq agent-shell-pet-scope 'global)
        (agent-shell-pet--renderer-hide agent-shell-pet--runtime))
      (setq agent-shell-pet--runtime nil)
      (when (eq agent-shell-pet-scope 'global)
        (agent-shell-pet--global-stop-display)))))

(defun agent-shell-pet--maybe-enable ()
  "Enable `agent-shell-pet-mode' in an initialized agent-shell buffer."
  (when (derived-mode-p 'agent-shell-mode)
    (agent-shell-pet-mode 1)))

;;;###autoload
(define-minor-mode global-agent-shell-pet-mode
  "Toggle agent-shell-pet in all initialized agent-shell buffers."
  :global t
  :group 'agent-shell-pet
  (if global-agent-shell-pet-mode
      (progn
        (add-hook 'agent-shell-mode-hook #'agent-shell-pet--maybe-enable)
        (add-hook 'buffer-list-update-hook
                  #'agent-shell-pet--maybe-dismiss-selected-notification)
        (dolist (buffer (buffer-list))
          (with-current-buffer buffer
            (when (derived-mode-p 'agent-shell-mode)
              (agent-shell-pet--maybe-enable)))))
    (remove-hook 'agent-shell-mode-hook #'agent-shell-pet--maybe-enable)
    (remove-hook 'buffer-list-update-hook
                 #'agent-shell-pet--maybe-dismiss-selected-notification)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when agent-shell-pet-mode
          (agent-shell-pet-mode -1))))))

;;;###autoload
(defun agent-shell-pet-show ()
  "Show the pet.
With `agent-shell-pet-scope' set to `global', restore a globally hidden pet
from any buffer.  Otherwise enable `agent-shell-pet-mode' in the current
buffer."
  (interactive)
  (cond
   ((and (eq agent-shell-pet-scope 'global)
         agent-shell-pet--global-display-suppressed
         (agent-shell-pet--runtime-p agent-shell-pet--global-runtime))
    (setq agent-shell-pet--global-display-suppressed nil)
    (agent-shell-pet--renderer-show agent-shell-pet--global-runtime)
    (when (agent-shell-pet--runtime-live-p agent-shell-pet--global-runtime)
      (agent-shell-pet--renderer-set-frame
       agent-shell-pet--global-runtime
       (agent-shell-pet--current-frame-path agent-shell-pet--global-runtime))
      (agent-shell-pet--schedule-next-frame agent-shell-pet--global-runtime))
    (agent-shell-pet--global-refresh))
   (t (agent-shell-pet-mode 1))))

;;;###autoload
(defun agent-shell-pet-hide ()
  "Hide the pet.
With `agent-shell-pet-scope' set to `global', hide the global pet from any
buffer.  Otherwise disable `agent-shell-pet-mode' in the current buffer."
  (interactive)
  (cond
   ((and (eq agent-shell-pet-scope 'global)
         (agent-shell-pet--runtime-p agent-shell-pet--global-runtime))
    (setq agent-shell-pet--global-display-suppressed t)
    (agent-shell-pet--cancel-animation agent-shell-pet--global-runtime)
    (agent-shell-pet--renderer-hide agent-shell-pet--global-runtime))
   (t (agent-shell-pet-mode -1))))

;;;###autoload
(defun agent-shell-pet-reset ()
  "Stop all pet timers and disable pets in live agent-shell buffers.

This is useful after reloading agent-shell-pet while old animation timers may
still be alive."
  (interactive)
  (agent-shell-pet--cancel-pet-timers)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p agent-shell-pet-mode)
        (agent-shell-pet-mode -1))))
  (clrhash agent-shell-pet--global-runtimes)
  (when (agent-shell-pet--runtime-p agent-shell-pet--global-runtime)
    (agent-shell-pet--cancel-animation agent-shell-pet--global-runtime)
    (agent-shell-pet--renderer-hide agent-shell-pet--global-runtime)
    (setq agent-shell-pet--global-runtime nil))
  (setq agent-shell-pet--global-display-suppressed nil)
  (message "agent-shell-pet reset complete"))

;;;###autoload
(defun agent-shell-pet-macos-build-helper ()
  "Build the macOS native renderer helper."
  (interactive)
  (unless (eq system-type 'darwin)
    (user-error "The macOS native renderer only builds on macOS"))
  (let ((default-directory (file-name-directory agent-shell-pet-macos-helper-path)))
    (unless (file-directory-p default-directory)
      (user-error "macOS renderer directory not found: %s" default-directory))
    (compile "make")))

;;;###autoload
(defun agent-shell-pet-wave ()
  "Ask the current pet to wave."
  (interactive)
  (unless agent-shell-pet--runtime
    (user-error "No pet runtime in this buffer"))
  (agent-shell-pet--set-transient-state agent-shell-pet--runtime 'waving 1.2))

(provide 'agent-shell-pet)

;;; agent-shell-pet.el ends here
