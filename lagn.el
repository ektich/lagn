;; (C) 2009 Rémi Vanicat <vanicat@debian.org>

;; lagn.el is a music player for Emacs that uses xmms2 as its backend
;; lagn stand for Lacking A Good Name

;;     This program is free software; you can redistribute it and/or
;;     modify it under the terms of the GNU General Public License as
;;     published by the Free Software Foundation; either version 3 of
;;     the License, or (at your option) any later version.

;;     This program is distributed in the hope that it will be useful,
;;     but WITHOUT ANY WARRANTY; without even the implied warranty of
;;     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;;     GNU General Public License for more details.

;;     You should have received a copy of the GNU General Public
;;     License along with this program; if not, write to the Free
;;     Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;;     Boston, MA 02110-1301 USA

;;; Commentary

;; For know, only some command for simple control of xmms2.

;; You can use lagn-list to have the current playlist.
;;
;; It create a *Playlist* buffer, with the following key
;;  SPC		lagn-toggle  (that is play/pause)
;;  g		lagn-list
;;  n		lagn-next
;;  p		lagn-prev
;;  s		lagn-stop

;; you can also directly use M-x lagn-play to start playback, and
;; M-x lagn-status to see the current playing situation

;; note that there is no automatic update on the Playlist for now

;; note also that I won't recommand it for manipulating big playlist

;;; Installing:

;; put this file in some direcories in your load path
;; add (require 'lagn) to you .emacs

;; you can also add keybinding: for example, for my multimedia keys:

;; (global-set-key [XF86AudioPlay] 'lagn-toggle)
;; (global-set-key [XF86Back] 'lagn-prev)
;; (global-set-key [XF86Forward] 'lagn-next)

;;; TODO
;; searching
;; edit current playlist
;; a mode to view/edit other playlist
;; a mode to view/edit collection
;; a mode to view current status
;; maybe status bar integration


(defvar lagn-playlist nil
  "The lagn playlist,
Its format is
  (POS LIST)
where POS is the current position and LIST is a list of
  (ID ARTIST ALBUM TITLE URL)
Where ID is the xmms2 id of the song, and ARTIST ALBUM TITLE maybe be nil
if xmms2 doesn't know them")

(defvar lagn-now-playing nil
  "The song that is being played now")

(defvar lagn-status nil
  "The status of xmms2, a symbol
can be paused, stopped, playing or nil
nil mean that there is noconnection or there was an error")

(defvar lagn-idle-update-timer nil)

(defvar lagn-info-cache (make-hash-table :weakness 'value))

(defgroup lagn ()
  "lagn is a client for xmms2 written in emacs lisp")

(defcustom lagn-command
  "nyxmms2"
  "The command to run for xmms2 command. Must be API compatible with nyxmms2"
  :group 'lagn
  :type 'string)

(defvar lagn-process ())
(defvar lagn-process-queue ()
  "tq queue for lagn")


;;; some function to read anwser from nyxmms2

(defun lagn-decode-info (info)
  (with-temp-buffer
    (insert info)
    (goto-char (point-min))
    (let (id title album artist url result)
      (search-forward-regexp "] id = \\([0-9]+\\)$")
      (setq id (string-to-number (match-string 1)))
      (goto-char (point-min))
      (search-forward-regexp "] url = \\([^\n]+\\)$")
      (setq url (match-string 1))
      (goto-char (point-min))
      (when (search-forward-regexp "] title = \\([^\n]+\\)$" () t)
	(setq title (match-string 1)))
      (goto-char (point-min))
      (when (search-forward-regexp "] album = \\([^\n]+\\)$" () t)
	(setq album (match-string 1)))
      (goto-char (point-min))
      (when (search-forward-regexp "] artist = \\([^\n]+\\)$" () t)
	(setq artist (match-string 1)))
      (setq result (list id artist album title url))
      (puthash id result lagn-info-cache)
      result)))


(defun lagn-decode-list (string)
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (let (current-pos id result list)
      (while (search-forward-regexp "^\\(->\\|  \\)\\[\\([0-9]+\\)/\\([0-9]+\\)\\] \\(.*\\)$" () t)
	(when (string= (match-string 1) "->")
	  (setq current-pos (string-to-number (match-string 2))))
	(setq id (string-to-number (match-string 3)))
	(setq result (gethash id lagn-info-cache))
	(unless result
	  (setq result (cons id (match-string 4)))
	  (lagn-info id))
	(push result list))
      (cons current-pos (nreverse list)))))


;;; function for the connection itself

(defun lagn-clean ()
  (when (processp lagn-process)
    (tq-close lagn-process-queue)))

(defun lagn-process-sentinel (proc event)
  ;; Is this only called when the process died ?
  (lagn-clean))

(defun lagn-callback-message (response)
  (message response))


(defun lagn-init-process ()		;TODO: add option for server and such
  (setq lagn-process (start-process "nyxmms2" " *nyxmms2*" lagn-command))
  (setq lagn-process-queue (tq-create lagn-process))
  (tq-enqueue lagn-process-queue "" "xmms2> " () 'ignore)
  (set-process-sentinel lagn-process 'lagn-process-sentinel)
  (set-process-query-on-exit-flag lagn-process ())
  (lagn-status))


(defun lagn-ensure-connected ()
  (unless (and lagn-process
	       (eq (process-status lagn-process)
		   'run))
    (lagn-init-process)))


(defun lagn-callback (closure answer)
  (apply (car closure) (substring answer 0 -7) (cdr closure)))

(defun lagn-call (callback command &rest args)
  (lagn-ensure-connected)
  (let ((question (with-output-to-string
		    (princ command)
		    (dolist (arg args)
		      (princ " ")
		      (princ arg))
		    (princ "\n"))))
    (tq-enqueue lagn-process-queue question "xmms2> " callback 'lagn-callback)))

;;; the commands

(defun lagn-exit-process ()
  (lagn-call '(ignore) "exit"))


(defun lagn-callback-current-info (response)
  (setq lagn-now-playing (lagn-decode-info response)))


(defun lagn-callback-status (response noshow)
  (unless (string-match "^\\(Paused\\|Stopped\\|Playing\\):" response)
    (setq lagn-status ())
    (error "wrong status message"))
  (cond
    ((string= (match-string 1 response) "Playing")
     (setq lagn-status 'playing))
    ((string= (match-string 1 response) "Paused")
     (setq lagn-status 'paused))
    ((string= (match-string 1 response) "Stopped")
     (setq lagn-status 'stopped)))
  (unless noshow (message response)))


(defun lagn-status (&optional noshow)
  (interactive)
  (lagn-call `(lagn-callback-status ,noshow) "status")
  (lagn-call '(lagn-callback-current-info) "info"))


(defun lagn-song-string (song)
  (if (listp (cdr song))
      (destructuring-bind (id artist album title url) song
	(unless artist (setq artist "Unknown"))
	(unless album (setq album "Unknown"))
	(unless title (setq title url))
	(setq artist (propertize artist 'face 'lagn-artist))
	(setq album (propertize album 'face 'lagn-album))
	(setq title (propertize title 'face 'lagn-title))
	(format "%s\n\tby %s from %s" title artist album))
      (propertize (cdr song) 'face 'lagn-song)))


(defun lagn-playlist-insert-song (song num)
  (let ((beg (point)))
    (insert-char ?  (length overlay-arrow-string))
    (insert " " (lagn-song-string song) "\n")
    (put-text-property beg (point) 'lagn-num num)
    (put-text-property beg (point) 'lagn-id (car song))
    (put-text-property beg (point) 'lagn-song song)))


(defun lagn-callback-list (response)
  (setq lagn-playlist (lagn-decode-list response))
  (with-current-buffer (lagn-playlist-buffer)
    (let ((buffer-read-only ())
	  (current-point (point))
	  (num 1)
	  (song-string)
	  (current-marker)
	  (current (car lagn-playlist)))
      (delete-region (point-min) (point-max))
      (goto-char (point-min))
      (insert (cond ((eq lagn-status 'playing) "Playing")
		    ((eq lagn-status 'paused) "Paused")
		    ((eq lagn-status 'stopped) "Stopped")
		    ('t "Unkown")))
      (insert "\n\n")

      (dolist (song (cdr lagn-playlist))
	(when (= num current)
	  (setq overlay-arrow-position (point-marker)))
	(lagn-playlist-insert-song song num)
	(setq num (1+ num)))
      (goto-char current-point))))


(defun lagn-list (&optional noshow)
  (interactive)
  (if (called-interactively-p)
      (switch-to-buffer (lagn-playlist-buffer)))
  (lagn-call '(lagn-callback-list) "list")
  (lagn-status noshow))


(defun lagn-callback-ok (response)
  ())


(defmacro lagn-simple (command)
  (let ((command-name (intern (concat "lagn-" command))))
    `(defun ,command-name ()
       (interactive)
       (lagn-call '(lagn-callback-ok) ,command)
       (lagn-list))))

(lagn-simple "play")
(lagn-simple "pause")
(lagn-simple "stop")
(lagn-simple "toggle")
(lagn-simple "next")
(lagn-simple "prev")


;; TODO: add docstrings
(defmacro lagn-command-with-pattern (command &optional pos xmms-command)
  (let ((command-name (intern (concat "lagn-" command)))
	(xmms-command (or xmms-command command)))
    `(defun ,command-name (&rest patterns)
       (interactive ,(if pos "sPattern Or Position: " "sPattern: "))
       (apply 'lagn-call '(lagn-callback-ok) ,xmms-command patterns)
       (lagn-list))))

(lagn-command-with-pattern "jump" t)
(lagn-command-with-pattern "remove" t)
(lagn-command-with-pattern "add")
(lagn-command-with-pattern "insert" () "add -n")


(defun lagn-callback-info (result)
  (let ((song (lagn-decode-info result)))
    (with-current-buffer (lagn-playlist-buffer)
      (save-excursion
	(let* ((beg (text-property-any (point-min) (point-max) 'lagn-id (car song)))
	       (num (get-text-property beg 'lagn-num))
	       (buffer-read-only ()))
	  (when beg
	    (goto-char beg)
	    (lagn-playlist-insert-song song num)
	    (delete-region (point)
			   (next-single-property-change beg 'lagn-id () (point-max)))))))))


(defun lagn-info (id)
  (lagn-call '(lagn-callback-info) "info id:" (number-to-string id)))


;;; The song list mode

(defface lagn-song
    '((t :weight bold))
  "Generic face for song"
  :group 'lagn)

(defface lagn-artist
    '((t :weight bold :inherit shadow))
  "Generic face for song"
  :group 'lagn)
(defface lagn-title
    '((t :inherit font-lock-function-name-face))
  "Generic face for song"
  :group 'lagn)
(defface lagn-album
    '((t :slant italic  :inherit shadow))
  "Generic face for song"
  :group 'lagn)





(define-derived-mode lagn-song-list-mode ()
  "Song list"
  "Major mode for lagn for song list

\\{lagn-playlist-mode-map}"
  :group 'lagn
  (setq buffer-undo-list t)
  (setq truncate-lines t)
  (setq buffer-read-only t))

(put 'lagn-song-list-mode 'mode-class 'special)



(progn					;should not be done on reload
  (suppress-keymap lagn-song-list-mode-map)
  (define-key lagn-song-list-mode-map "s" 'lagn-search)
  (define-key lagn-song-list-mode-map "q" 'bury-buffer)
  (define-key lagn-song-list-mode-map " " 'scroll-up))



(defun lagn-song-list-region-song (prop)
  (let ((beg (min (point) (mark)))
	(pos (max (point) (mark)))
	(res ())
	num)
    (setq pos (previous-single-property-change pos prop () beg))
    (while (>= pos beg)
      (setq num (get-text-property pos prop))
      (when num (push num res))
      (setq pos (previous-single-property-change pos prop)))
    res))



(define-derived-mode lagn-search-mode lagn-song-list-mode
  "Search"
  "Major mode to view search"
  :group 'lagn)


(defun lagn-search-callback (answer)
  (with-current-buffer (get-buffer "*Lagn-Search*")
    (let ((buffer-read-only ()))
      (delete-region (point-min) (point-max))
      (insert answer)
      (goto-char (point-min))
      (forward-line 2)
      (delete-region (point-min) (point))
      (while (looking-at "\\([0-9]+\\) *| \\([^|]*[^| ]\\|\\) *| \\([^|]*[^| ]\\|\\) *| \\([^\n]*[^\n ]\\|\\) *\n")
	(let ((id (string-to-int (match-string 1)))
	      (artist (match-string 2))
	      (album (match-string 3))
	      (title (match-string 4))
	      song)
	  (setq song (gethash id lagn-info-cache (list id artist album title "")))
	  (delete-region (point) (match-end 0))
	  (lagn-playlist-insert-song song 0))) ; MAYBE to something with the num
      (when (looking-at "------------------------*\\[.*\\]-*")
	(delete-region (point) (point-max))))))

(defun lagn-search (search)
  (interactive "SSearch: ")
  (pop-to-buffer "*Lagn-Search*")
  (lagn-search-mode)
  (lagn-call '(lagn-search-callback) "search" search))

(defun lagn-search-artist (search)
  (interactive "SSearch: ")
  (lagn-search (format "artist: *\"%s\"*" search)))

(defun lagn-search-album (search)
  (interactive "SSearch: ")
  (lagn-search (format "album: *\"%s\"*" search)))

(defun lagn-search-title (search)
  (interactive "SSearch: ")
  (lagn-search (format "title: *\"%s\"*" search)))


;; The current playlist mode


(define-derived-mode lagn-playlist-mode lagn-song-list-mode ; TODO: move song
  "Xmms2"
  "Major mode for the Current Xmms2 playlist

\\{lagn-playlist-mode-map}"
  :group 'lagn
  (when (timerp lagn-idle-update-timer)
    (cancel-timer lagn-idle-update-timer))
  (setq lagn-idle-update-timer (run-with-idle-timer 3 t 'lagn-list t)))


(defun lagn-playlist-buffer ()
  (let ((buffer (get-buffer-create "*Playlist*")))
    (with-current-buffer buffer
      (unless (eq major-mode 'lagn-playlist-mode)
	(lagn-playlist-mode)))
    buffer))


(defun lagn-playlist-middle-click (event)
  (interactive "e")
  (let (window pos num)
    (save-excursion
      (setq window (posn-window (event-end event))
	    pos (posn-point (event-end event)))
      (if (not (windowp window))
	  (error "No song selected"))
      (with-current-buffer (window-buffer window)
	(setq num (get-text-property pos 'lagn-num))
	(lagn-jump num)))))



(defun lagn-playlist-jump ()
  (interactive)
  (lagn-jump (get-text-property (point) 'lagn-num)))

(defun lagn-playlist-remove ()
  (interactive)
  (if mark-active
      (apply 'lagn-remove (lagn-song-list-region-song 'lagn-num))
      (lagn-remove (get-text-property (point) 'lagn-num))))

(progn					;should not be done on reload
  (define-key lagn-playlist-mode-map " " 'lagn-toggle)
  (define-key lagn-playlist-mode-map "n" 'lagn-next)
  (define-key lagn-playlist-mode-map "p" 'lagn-prev)
  (define-key lagn-playlist-mode-map "n" 'lagn-next)
  (define-key lagn-playlist-mode-map "g" 'lagn-list)
  (define-key lagn-playlist-mode-map "\\r" 'lagn-playlist-jump)
  (define-key lagn-playlist-mode-map "d" 'lagn-playlist-remove)
  (define-key lagn-playlist-mode-map [mouse-2] 'lagn-playlist-middle-click))


(provide 'lagn)
