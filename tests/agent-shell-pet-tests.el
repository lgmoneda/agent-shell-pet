;;; agent-shell-pet-tests.el --- Tests for agent-shell-pet -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'agent-shell-pet)

(defun agent-shell-pet-tests--write-webp-atlas (file)
  "Write a tiny WebP-like FILE header with Codex atlas dimensions."
  (let ((coding-system-for-write 'binary))
    (with-temp-file file
      (set-buffer-multibyte nil)
      ;; RIFF size is not currently validated by the loader; the VP8X payload
      ;; carries the dimensions we care about.
      (insert (unibyte-string
               ?R ?I ?F ?F 30 0 0 0 ?W ?E ?B ?P
               ?V ?P ?8 ?X 10 0 0 0
               0 0 0 0
               #xff #x05 0
               #x4f #x07 0)))))

(defun agent-shell-pet-tests--write-png-header (file width height)
  "Write a minimal PNG FILE header with WIDTH and HEIGHT."
  (let ((coding-system-for-write 'binary))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert "\211PNG\r\n\032\n")
      (insert (unibyte-string 0 0 0 13 ?I ?H ?D ?R
                              (logand (ash width -24) #xff)
                              (logand (ash width -16) #xff)
                              (logand (ash width -8) #xff)
                              (logand width #xff)
                              (logand (ash height -24) #xff)
                              (logand (ash height -16) #xff)
                              (logand (ash height -8) #xff)
                              (logand height #xff))))))

(ert-deftest agent-shell-pet-test-webp-atlas-size ()
  (let ((file (make-temp-file "agent-shell-pet" nil ".webp")))
    (unwind-protect
        (progn
          (agent-shell-pet-tests--write-webp-atlas file)
          (should (equal (agent-shell-pet--image-size file) '(1536 . 1872)))
          (should (agent-shell-pet--valid-atlas-p file)))
      (delete-file file))))

(ert-deftest agent-shell-pet-test-png-size ()
  (let ((file (make-temp-file "agent-shell-pet" nil ".png")))
    (unwind-protect
        (progn
          (agent-shell-pet-tests--write-png-header file 1536 1872)
          (should (equal (agent-shell-pet--image-size file) '(1536 . 1872)))
          (should (agent-shell-pet--valid-atlas-p file)))
      (delete-file file))))

(ert-deftest agent-shell-pet-test-discovers-valid-custom-pet ()
  (let* ((root (make-temp-file "agent-shell-pet" t))
         (agent-shell-pet-codex-home root)
         (agent-shell-pet-user-pets-directory
          (expand-file-name "user-pets/" root))
         (agent-shell-pet-bundled-pets-directory
          (expand-file-name "bundled-pets/" root))
         (pet-dir (expand-file-name "pets/sprout/" root))
         (atlas (expand-file-name "spritesheet.webp" pet-dir)))
    (unwind-protect
        (progn
          (make-directory pet-dir t)
          (agent-shell-pet-tests--write-webp-atlas atlas)
          (with-temp-file (expand-file-name "pet.json" pet-dir)
            (insert "{\n"
                    "  \"id\": \"sprout\",\n"
                    "  \"displayName\": \"Sprout\",\n"
                    "  \"description\": \"A test pet.\",\n"
                    "  \"spritesheetPath\": \"spritesheet.webp\"\n"
                    "}\n"))
          (let ((pets (agent-shell-pet-list-pets)))
            (should (= (length pets) 1))
            (should (equal (agent-shell-pet-id (car pets)) "sprout"))
            (should (equal (agent-shell-pet-display-name (car pets)) "Sprout"))))
      (delete-directory root t))))

(ert-deftest agent-shell-pet-test-rejects-traversing-spritesheet-path ()
  (let* ((root (make-temp-file "agent-shell-pet" t))
         (agent-shell-pet-codex-home root)
         (agent-shell-pet-user-pets-directory
          (expand-file-name "user-pets/" root))
         (agent-shell-pet-bundled-pets-directory
          (expand-file-name "bundled-pets/" root))
         (pet-dir (expand-file-name "pets/sprout/" root))
         (atlas (expand-file-name "pets/spritesheet.webp" root)))
    (unwind-protect
        (progn
          (make-directory pet-dir t)
          (agent-shell-pet-tests--write-webp-atlas atlas)
          (with-temp-file (expand-file-name "pet.json" pet-dir)
            (insert "{\n"
                    "  \"id\": \"sprout\",\n"
                    "  \"spritesheetPath\": \"../spritesheet.webp\"\n"
                    "}\n"))
          (should-not (agent-shell-pet-list-pets)))
      (delete-directory root t))))

(ert-deftest agent-shell-pet-test-mode-enable-is-idempotent ()
  "`agent-shell-pet-mode' must not rebuild a live buffer-local runtime.
Re-evaluating user config calls `global-agent-shell-pet-mode 1', which
propagates to every agent-shell buffer; without this guarantee the
previous renderer (e.g. macOS helper subprocess), animation timer, and
event subscriptions are orphaned and a duplicate pet appears on screen."
  (let* ((existing-pet (agent-shell-pet--make
                        :id "sprout"
                        :display-name "Sprout"
                        :directory "/tmp"
                        :spritesheet-path "/tmp/spritesheet.webp"))
         (existing (agent-shell-pet--make-runtime
                    :pet existing-pet
                    :shell-buffer nil
                    :renderer 'macos-native
                    :state 'idle
                    :status-text ""
                    :frame-index 0))
         (make-runtime-calls 0)
         (renderer-show-calls 0))
    ;; The guard short-circuits before any of these are called; the mocks
    ;; just count invocations to prove the body did not run.  If the
    ;; regression returns, `--make-runtime' would be hit, the mock would
    ;; signal, and the test would fail loudly rather than rebuilding state.
    (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
              ((symbol-function 'require) (lambda (&rest _) nil))
              ((symbol-function 'agent-shell-pet--select-pet)
               (lambda () existing-pet))
              ((symbol-function 'agent-shell-pet--ensure-frame-cache)
               (lambda (&rest _) nil))
              ((symbol-function 'agent-shell-pet--make-runtime)
               (lambda (&rest _) (cl-incf make-runtime-calls) existing))
              ((symbol-function 'agent-shell-pet--renderer-show)
               (lambda (&rest _) (cl-incf renderer-show-calls)))
              ((symbol-function 'agent-shell-pet--renderer-set-frame)
               (lambda (&rest _) nil))
              ((symbol-function 'agent-shell-pet--schedule-next-frame)
               (lambda (&rest _) nil))
              ((symbol-function 'agent-shell-pet--subscribe)
               (lambda (&rest _) nil)))
      (with-temp-buffer
        (setf (agent-shell-pet--runtime-shell-buffer existing) (current-buffer))
        (setq-local agent-shell-pet--runtime existing)
        (setq-local agent-shell-pet-mode t)
        (agent-shell-pet-mode 1)
        (should (eq agent-shell-pet--runtime existing))
        (should (= make-runtime-calls 0))
        (should (= renderer-show-calls 0))))))

(ert-deftest agent-shell-pet-test-accepts-symlinked-spritesheet ()
  "Spritesheets staged as symlinks to a real file outside the pet
directory must still load — package managers like straight.el ship
non-Lisp resources this way."
  (skip-unless (executable-find "ln"))
  (let* ((root (make-temp-file "agent-shell-pet" t))
         (agent-shell-pet-codex-home root)
         (agent-shell-pet-user-pets-directory
          (expand-file-name "user-pets/" root))
         (agent-shell-pet-bundled-pets-directory
          (expand-file-name "bundled-pets/" root))
         (pet-dir (expand-file-name "pets/sprout/" root))
         (real-atlas (expand-file-name "real-store/spritesheet.webp" root))
         (linked-atlas (expand-file-name "spritesheet.webp" pet-dir)))
    (unwind-protect
        (progn
          (make-directory pet-dir t)
          (make-directory (file-name-directory real-atlas) t)
          (agent-shell-pet-tests--write-webp-atlas real-atlas)
          (make-symbolic-link real-atlas linked-atlas)
          (with-temp-file (expand-file-name "pet.json" pet-dir)
            (insert "{\n"
                    "  \"id\": \"sprout\",\n"
                    "  \"spritesheetPath\": \"spritesheet.webp\"\n"
                    "}\n"))
          (let ((pets (agent-shell-pet-list-pets)))
            (should (= (length pets) 1))
            (should (equal (agent-shell-pet-id (car pets)) "sprout"))))
      (delete-directory root t))))

(ert-deftest agent-shell-pet-test-discovers-user-pets-without-codex ()
  (let* ((root (make-temp-file "agent-shell-pet" t))
         (agent-shell-pet-include-codex-pets nil)
         (agent-shell-pet-user-pets-directory
          (expand-file-name "agent-shell-pets/" root))
         (agent-shell-pet-bundled-pets-directory
          (expand-file-name "bundled-pets/" root))
         (pet-dir (expand-file-name "sprout/" agent-shell-pet-user-pets-directory))
         (atlas (expand-file-name "spritesheet.webp" pet-dir)))
    (unwind-protect
        (progn
          (make-directory pet-dir t)
          (agent-shell-pet-tests--write-webp-atlas atlas)
          (with-temp-file (expand-file-name "pet.json" pet-dir)
            (insert "{\n"
                    "  \"id\": \"sprout\",\n"
                    "  \"displayName\": \"Sprout\",\n"
                    "  \"spritesheetPath\": \"spritesheet.webp\"\n"
                    "}\n"))
          (let ((pets (agent-shell-pet-list-pets)))
            (should (= (length pets) 1))
            (should (equal (agent-shell-pet-id (car pets)) "sprout"))))
      (delete-directory root t))))

(ert-deftest agent-shell-pet-test-merges-user-and-codex-pet-roots ()
  (let* ((root (make-temp-file "agent-shell-pet" t))
         (agent-shell-pet-codex-home (expand-file-name "codex/" root))
         (agent-shell-pet-user-pets-directory
          (expand-file-name "agent-shell-pets/" root))
         (agent-shell-pet-bundled-pets-directory
          (expand-file-name "bundled-pets/" root))
         (user-pet-dir (expand-file-name "sprout/" agent-shell-pet-user-pets-directory))
         (codex-pet-dir (expand-file-name "pets/canarinho/" agent-shell-pet-codex-home)))
    (unwind-protect
        (progn
          (dolist (pair `((,user-pet-dir . "sprout")
                          (,codex-pet-dir . "canarinho")))
            (make-directory (car pair) t)
            (agent-shell-pet-tests--write-webp-atlas
             (expand-file-name "spritesheet.webp" (car pair)))
            (with-temp-file (expand-file-name "pet.json" (car pair))
              (insert "{\n"
                      "  \"id\": \"" (cdr pair) "\",\n"
                      "  \"displayName\": \"" (cdr pair) "\",\n"
                      "  \"spritesheetPath\": \"spritesheet.webp\"\n"
                      "}\n")))
          (should (equal (mapcar #'agent-shell-pet-id
                                 (agent-shell-pet-list-pets))
                         '("sprout" "canarinho"))))
      (delete-directory root t))))

(ert-deftest agent-shell-pet-test-read-pet-uses-completing-read ()
  (let* ((root (make-temp-file "agent-shell-pet" t))
         (agent-shell-pet-codex-home (expand-file-name "codex/" root))
         (agent-shell-pet-user-pets-directory
          (expand-file-name "agent-shell-pets/" root))
         (agent-shell-pet-bundled-pets-directory
          (expand-file-name "bundled-pets/" root))
         (sprout-dir (expand-file-name "agent-shell-pets/sprout/" root))
         (canarinho-dir (expand-file-name "pets/canarinho/" agent-shell-pet-codex-home))
         (agent-shell-pet-id "sprout")
         captured-default)
    (unwind-protect
        (progn
          (dolist (pair `((,sprout-dir . ("sprout" . "Sprout"))
                          (,canarinho-dir . ("canarinho" . "Canarinho"))))
            (make-directory (car pair) t)
            (agent-shell-pet-tests--write-webp-atlas
             (expand-file-name "spritesheet.webp" (car pair)))
            (with-temp-file (expand-file-name "pet.json" (car pair))
              (insert "{\n"
                      "  \"id\": \"" (cadr pair) "\",\n"
                      "  \"displayName\": \"" (cddr pair) "\",\n"
                      "  \"spritesheetPath\": \"spritesheet.webp\"\n"
                      "}\n")))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt collection _predicate _require-match
                              _initial-input _hist default)
                       (setq captured-default default)
                       (should (= (length collection) 2))
                       "Canarinho (canarinho)")))
            (let ((pet (agent-shell-pet--read-pet)))
              (should (equal (agent-shell-pet-id pet) "canarinho"))
              (should (equal captured-default "Sprout (sprout)")))))
      (delete-directory root t))))

(ert-deftest agent-shell-pet-test-select-avatar-switches-active-runtime-in-place ()
  (let* ((old-pet (agent-shell-pet--make
                   :id "sprout"
                   :display-name "Sprout"
                   :directory "/tmp/sprout"
                   :spritesheet-path "/tmp/sprout/spritesheet.webp"))
         (new-pet (agent-shell-pet--make
                   :id "canarinho"
                   :display-name "Canarinho"
                   :directory "/tmp/canarinho"
                   :spritesheet-path "/tmp/canarinho/spritesheet.webp"))
         (agent-shell-pet-scope 'buffer)
         (agent-shell-pet--global-runtime nil)
         (set-frame-calls 0)
         (scheduled-calls 0)
         (runtime nil))
    (cl-letf (((symbol-function 'agent-shell-pet--ensure-frame-cache)
               (lambda (&rest _) nil))
              ((symbol-function 'agent-shell-pet--current-frame-path)
               (lambda (&rest _) "/tmp/canarinho/idle-00.png"))
              ((symbol-function 'agent-shell-pet--renderer-set-frame)
               (lambda (&rest _) (cl-incf set-frame-calls)))
              ((symbol-function 'agent-shell-pet--schedule-next-frame)
               (lambda (&rest _) (cl-incf scheduled-calls))))
      (with-temp-buffer
        (setq runtime
              (agent-shell-pet--make-runtime
               :pet old-pet
               :shell-buffer (current-buffer)
               :renderer 'child-frame
               :state 'idle
               :status-text nil
               :frame-index 3))
        (setq-local agent-shell-pet--runtime runtime)
        (agent-shell-pet-select-avatar new-pet)
        (should (eq (agent-shell-pet--runtime-pet runtime) new-pet))
        (should (= (agent-shell-pet--runtime-frame-index runtime) 0))
        (should (equal agent-shell-pet-id "canarinho"))
        (should (= set-frame-calls 1))
        (should (= scheduled-calls 1))))))

(ert-deftest agent-shell-pet-test-codex-pets-input-parsing ()
  (should (equal (agent-shell-pet--codex-pets-id-from-input "goku")
                 "goku"))
  (should (equal (agent-shell-pet--codex-pets-id-from-input
                  "https://codex-pets.net/#/?q=goku")
                 "goku"))
  (should (equal (agent-shell-pet--codex-pets-id-from-input
                  "https://codex-pets.net/#/pets/canarinho")
                 "canarinho"))
  (should (equal (agent-shell-pet--codex-pets-id-from-input
                  "https://codex-pets.net/#/pets/kid-goku")
                 "kid-goku"))
  (should (equal (agent-shell-pet--codex-pets-id-from-input
                  "https://codex-pets.net/share/son-goku")
                 "son-goku")))

(ert-deftest agent-shell-pet-test-install-directory-targets ()
  (let ((agent-shell-pet-user-pets-directory "/tmp/agent-shell-pets/")
        (agent-shell-pet-codex-home "/tmp/codex-home/")
        (agent-shell-pet-install-target 'agent-shell-pet))
    (should (equal (agent-shell-pet--install-directory)
                   "/tmp/agent-shell-pets/"))
    (should (equal (agent-shell-pet--install-directory 'codex)
                   "/tmp/codex-home/pets/"))))

(ert-deftest agent-shell-pet-test-codex-pets-read-json-retrieve-failure ()
  (cl-letf (((symbol-function 'url-retrieve-synchronously)
             (lambda (&rest _args) nil)))
    (should-error (agent-shell-pet--codex-pets-read-json "https://example.invalid")
                  :type 'user-error)))

(ert-deftest agent-shell-pet-test-tool-call-state-mapping ()
  (should (eq (agent-shell-pet--tool-call-state '((:status . "failed")))
              'failed))
  (should (eq (agent-shell-pet--tool-call-state '((:status . "completed")))
              'review))
  (should (eq (agent-shell-pet--tool-call-state '((:status . "in_progress")
                                                  (:kind . "read")))
              'review))
  (should (eq (agent-shell-pet--tool-call-state '((:status . "in_progress")
                                                  (:kind . "execute")))
              'running)))

(ert-deftest agent-shell-pet-test-tool-call-text ()
  (let ((agent-shell-pet-speech-style 'pet))
    (should (equal (agent-shell-pet--tool-call-text
                    '((:status . "in_progress")
                      (:kind . "execute")
                      (:title . "Bash\n  npm test")))
                   "Running: npm test"))
    (should (equal (agent-shell-pet--tool-call-text
                    '((:status . "completed")
                      (:title . "Read README.org")))
                   "Thinking"))
    (should (equal (agent-shell-pet--tool-call-text
                    '((:status . "failed")
                      (:title . "Edit app.el")))
                   "I'm stuck"))
    (should (equal (agent-shell-pet--tool-call-text
                    '((:status . "in_progress")
                      (:kind . "read")))
                   "Reading")))
  (let ((agent-shell-pet-speech-style 'technical)
        (agent-shell-pet-chatty t))
    (should (equal (agent-shell-pet--tool-call-text
                    '((:status . "completed")
                      (:title . "Read README.org")))
                   "Done: README.org"))))

(ert-deftest agent-shell-pet-test-turn-complete-returns-to-idle ()
  (let (calls scheduled)
    (cl-letf (((symbol-function 'agent-shell-pet--set-state)
               (lambda (_runtime state &optional status-text)
                 (push (list state status-text) calls)))
              ((symbol-function 'agent-shell-pet--runtime-live-p)
               (lambda (_runtime) t))
              ((symbol-function 'run-at-time)
               (lambda (seconds _repeat function &rest args)
                 (setq scheduled (list seconds function args))
                 'agent-shell-pet-test-timer)))
      (let ((runtime (agent-shell-pet--make-runtime))
            (agent-shell-pet-completion-display-seconds 2.5)
            (agent-shell-pet-idle-status-text nil))
        (agent-shell-pet--handle-event
         runtime
         '((:event . turn-complete)
           (:data . ((:stop-reason . "end_turn")))))
        (should (equal (pop calls) '(review "Turn complete")))
        (should (equal (car scheduled) 2.5))
        (apply (cadr scheduled) (caddr scheduled))
        (should (equal (pop calls) '(idle nil)))))))

(ert-deftest agent-shell-pet-test-completion-duration-default ()
  (should (= agent-shell-pet-completion-display-seconds 10.0)))

(ert-deftest agent-shell-pet-test-size-presets ()
  (let ((agent-shell-pet-scale 1.0))
    (let ((agent-shell-pet-size 'large))
      (should (= (agent-shell-pet--effective-scale) 1.0)))
    (let ((agent-shell-pet-size 'medium))
      (should (= (agent-shell-pet--effective-scale) 0.75)))
    (let ((agent-shell-pet-size 'small))
      (should (= (agent-shell-pet--effective-scale) 0.55)))))

(ert-deftest agent-shell-pet-test-scale-multiplies-size-preset ()
  (let ((agent-shell-pet-size 'medium)
        (agent-shell-pet-scale 2.0))
    (should (= (agent-shell-pet--effective-scale) 1.5))))

(ert-deftest agent-shell-pet-test-scope-defaults-to-global ()
  (should (eq agent-shell-pet-scope 'global)))

(ert-deftest agent-shell-pet-test-global-notification-stack-sorts-by-urgency ()
  (let* ((agent-shell-pet--global-runtimes (make-hash-table :test #'eq))
         (agent-shell-pet-max-notifications 2)
         (pet (agent-shell-pet--make :id "sprout"))
         (review-buffer (generate-new-buffer "Review Agent"))
         (running-buffer (generate-new-buffer "Running Agent"))
         (failed-buffer (generate-new-buffer "Failed Agent")))
    (unwind-protect
        (let ((review (agent-shell-pet--make-runtime
                       :pet pet
                       :shell-buffer review-buffer
                       :renderer 'global
                       :state 'review
                       :status-text "Turn complete"
                       :frame-index 0
                       :updated-at (seconds-to-time 300)))
              (running (agent-shell-pet--make-runtime
                        :pet pet
                        :shell-buffer running-buffer
                        :renderer 'global
                        :state 'running
                        :status-text "Thinking"
                        :frame-index 0
                        :updated-at (seconds-to-time 200)))
              (failed (agent-shell-pet--make-runtime
                       :pet pet
                       :shell-buffer failed-buffer
                       :renderer 'global
                       :state 'failed
                       :status-text "I'm stuck"
                       :frame-index 0
                       :updated-at (seconds-to-time 100))))
          (puthash review-buffer review agent-shell-pet--global-runtimes)
          (puthash running-buffer running agent-shell-pet--global-runtimes)
          (puthash failed-buffer failed agent-shell-pet--global-runtimes)
          (should (equal
                   (mapcar (lambda (card) (alist-get 'body card))
                           (agent-shell-pet--global-notification-cards))
                   '("I'm stuck" "Thinking"))))
      (mapc (lambda (buffer)
              (when (buffer-live-p buffer)
                (kill-buffer buffer)))
            (list review-buffer running-buffer failed-buffer)))))

(ert-deftest agent-shell-pet-test-global-notification-dismisses-current-session ()
  (let* ((agent-shell-pet--global-runtimes (make-hash-table :test #'eq))
         (pet (agent-shell-pet--make :id "sprout"))
         (buffer (generate-new-buffer "Visited Agent"))
         (runtime (agent-shell-pet--make-runtime
                   :pet pet
                   :shell-buffer buffer
                   :renderer 'global
                   :state 'review
                   :status-text "Turn complete"
                   :frame-index 0
                   :updated-at (seconds-to-time 100))))
    (unwind-protect
        (progn
          (puthash buffer runtime agent-shell-pet--global-runtimes)
          (should (= (length (agent-shell-pet--global-notification-cards)) 1))
          (agent-shell-pet--dismiss-runtime-notification runtime)
          (should-not (agent-shell-pet--global-notification-cards))
          (setf (agent-shell-pet--runtime-updated-at runtime)
                (seconds-to-time 101))
          (should (= (length (agent-shell-pet--global-notification-cards)) 1)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-shell-pet-test-prompt-ready-does-not-flash-completion-away ()
  (let (calls scheduled)
    (cl-letf (((symbol-function 'agent-shell-pet--set-state)
               (lambda (_runtime state &optional status-text)
                 (push (list state status-text) calls)))
              ((symbol-function 'agent-shell-pet--runtime-live-p)
               (lambda (_runtime) t))
              ((symbol-function 'run-at-time)
               (lambda (seconds _repeat function &rest args)
                 (setq scheduled (list seconds function args))
                 'agent-shell-pet-test-timer)))
      (let ((runtime (agent-shell-pet--make-runtime))
            (agent-shell-pet-completion-display-seconds 2.5))
        (agent-shell-pet--handle-event
         runtime
         '((:event . turn-complete)
           (:data . ((:stop-reason . "end_turn")))))
        (agent-shell-pet--handle-event runtime '((:event . prompt-ready)))
        (should (equal calls '((review "Turn complete"))))
        (apply (cadr scheduled) (caddr scheduled))
        (should (equal (pop calls) '(idle nil)))))))

(ert-deftest agent-shell-pet-test-input-submitted-starts-thinking ()
  (let (calls)
    (cl-letf (((symbol-function 'agent-shell-pet--set-state)
               (lambda (_runtime state &optional status-text)
                 (push (list state status-text) calls))))
      (let ((agent-shell-pet-thinking-status-text "Thinking"))
        (agent-shell-pet--handle-event
         (agent-shell-pet--make-runtime)
         '((:event . input-submitted)))
        (should (equal (pop calls) '(running "Thinking")))))))

(ert-deftest agent-shell-pet-test-input-submitted-cancels-completion ()
  (let (calls cancelled)
    (cl-letf (((symbol-function 'agent-shell-pet--set-state)
               (lambda (_runtime state &optional status-text)
                 (push (list state status-text) calls)))
              ((symbol-function 'timerp)
               (lambda (timer) (eq timer 'agent-shell-pet-test-timer)))
              ((symbol-function 'cancel-timer)
               (lambda (_timer) (setq cancelled t))))
      (let ((runtime (agent-shell-pet--make-runtime
                      :transient-timer 'agent-shell-pet-test-timer))
            (agent-shell-pet-thinking-status-text "Thinking"))
        (agent-shell-pet--handle-event runtime '((:event . input-submitted)))
        (should cancelled)
        (should-not (agent-shell-pet--runtime-transient-timer runtime))
        (should (equal (pop calls) '(running "Thinking")))))))

(ert-deftest agent-shell-pet-test-turn-success-p-accepts-common-shapes ()
  (should (agent-shell-pet--turn-success-p '((:stop-reason . "end_turn"))))
  (should (agent-shell-pet--turn-success-p '((:stop-reason . end_turn))))
  (should (agent-shell-pet--turn-success-p '((stopReason . "end_turn"))))
  (should-not (agent-shell-pet--turn-success-p '((:stop-reason . "max_turns")))))

(ert-deftest agent-shell-pet-test-macos-card-status ()
  (should (equal (agent-shell-pet--macos-card-status
                  (agent-shell-pet--make-runtime :state 'running
                                                 :status-text "On it"))
                 "thinking"))
  (should (equal (agent-shell-pet--macos-card-status
                  (agent-shell-pet--make-runtime :state 'review
                                                 :status-text "Turn complete"))
                 "done"))
  (should (equal (agent-shell-pet--macos-card-status
                  (agent-shell-pet--make-runtime :state 'failed
                                                 :status-text "Stuck"))
                 "error")))

(ert-deftest agent-shell-pet-test-speech-bubble-theme-option ()
  (let ((agent-shell-pet-speech-bubble-theme 'light))
    (should (equal (symbol-name agent-shell-pet-speech-bubble-theme)
                   "light"))))

(ert-deftest agent-shell-pet-test-stale-runtime-tick-is-ignored ()
  (let ((runtime (agent-shell-pet--make-runtime
                  :state 'review
                  :status-text "Turn complete"
                  :frame-index [t 1 2 nil agent-shell-pet--tick nil]
                  :renderer 'child-frame)))
    (should-not (agent-shell-pet--runtime-live-p runtime))
    (should-not (agent-shell-pet--tick runtime))))

(ert-deftest agent-shell-pet-test-hide-from-any-buffer-suppresses-global ()
  "`agent-shell-pet-hide' must hide the global pet regardless of caller buffer."
  (let* ((agent-shell-pet-scope 'global)
         (agent-shell-pet--global-runtimes (make-hash-table :test #'eq))
         (agent-shell-pet--global-display-suppressed nil)
         (pet (agent-shell-pet--make :id "sprout"))
         (originating-buffer (generate-new-buffer "Originating"))
         (other-buffer (generate-new-buffer "Other"))
         (originating-runtime (agent-shell-pet--make-runtime
                               :pet pet
                               :shell-buffer originating-buffer
                               :renderer 'global
                               :state 'idle
                               :frame-index 0
                               :updated-at (current-time)))
         (other-runtime (agent-shell-pet--make-runtime
                         :pet pet
                         :shell-buffer other-buffer
                         :renderer 'global
                         :state 'idle
                         :frame-index 0
                         :updated-at (current-time)))
         (global-runtime (agent-shell-pet--make-runtime
                          :pet pet
                          :shell-buffer originating-buffer
                          :renderer 'child-frame
                          :state 'idle
                          :frame-index 0
                          :global-display-p t
                          :updated-at (current-time)))
         (agent-shell-pet--global-runtime global-runtime)
         hide-calls cancel-calls)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-pet--renderer-hide)
                   (lambda (rt) (push rt hide-calls)))
                  ((symbol-function 'agent-shell-pet--cancel-animation)
                   (lambda (rt) (push rt cancel-calls))))
          (puthash originating-buffer originating-runtime
                   agent-shell-pet--global-runtimes)
          (puthash other-buffer other-runtime
                   agent-shell-pet--global-runtimes)
          (with-current-buffer other-buffer
            (agent-shell-pet-hide))
          (should agent-shell-pet--global-display-suppressed)
          (should (memq global-runtime hide-calls))
          (should (memq global-runtime cancel-calls))
          ;; Both per-buffer runtimes remain registered: hide must not
          ;; depend on tearing them down.
          (should (= (hash-table-count agent-shell-pet--global-runtimes) 2)))
      (when (buffer-live-p originating-buffer) (kill-buffer originating-buffer))
      (when (buffer-live-p other-buffer) (kill-buffer other-buffer)))))

(ert-deftest agent-shell-pet-test-global-refresh-skipped-while-suppressed ()
  "Frame updates from registered runtimes must not re-show a hidden pet."
  (let* ((agent-shell-pet-scope 'global)
         (agent-shell-pet--global-display-suppressed t)
         (pet (agent-shell-pet--make :id "sprout"))
         (buffer (generate-new-buffer "Refresh"))
         (global-runtime (agent-shell-pet--make-runtime
                          :pet pet
                          :shell-buffer buffer
                          :renderer 'child-frame
                          :state 'idle
                          :frame-index 0
                          :global-display-p t
                          :updated-at (current-time)))
         (agent-shell-pet--global-runtime global-runtime)
         set-frame-calls)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-pet--renderer-set-frame)
                   (lambda (&rest args) (push args set-frame-calls)))
                  ((symbol-function 'agent-shell-pet--runtime-live-p)
                   (lambda (_rt) t)))
          (agent-shell-pet--global-refresh)
          (should-not set-frame-calls))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'agent-shell-pet-tests)

;;; agent-shell-pet-tests.el ends here
