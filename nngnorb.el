;;; nngnorb.el --- Gnorb backend for Gnus -*- lexical-binding: t -*-

;; Copyright (C) 2018  Free Software Foundation, Inc.

;; Author: Eric Abrahamsen <eric@ericabrahamsen.net.>

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This is a backend for supporting Gnorb-related stuff. I'm going to
;; regret this, I know.

;; It started off just with wanting to collect all the gnus links in a
;; subtree, and display all the messages in an ephemeral group. But it
;; doesn't seem possible to create ephemeral groups without
;; associating them with a server, and which server would that be?
;; Nnir also provides a nice interface to creating ephemeral groups,
;; but again, it relies on a server parameter to know which nnir
;; engine to use, and if you try to fake it it still craps out.

;; So this file is a copy-pasta from nnnil.el -- I'm trying to keep
;; this as simple as possible. Right now it does nothing but serving
;; as a place to hang ephemeral groups made with nnir searches of
;; message from the rest of your gnus installation. Enjoy.

;;; Code:

(require 'gnus)
(eval-and-compile
  (require 'nnheader)
  (require 'nnir))

(defvar nngnorb-status-string "")

(defvar nngnorb-attachment-file-list nil
  "A place to store Org attachments relevant to the subtree being
  viewed.")

(make-variable-buffer-local 'nngnorb-attachment-file-list)

(gnus-declare-backend "nngnorb" 'post-mail 'virtual)

(add-to-list 'nnir-method-default-engines '(nngnorb . gnorb))

(add-to-list 'nnir-engines
	     '(gnorb nnir-run-gnorb))

(defun nnir-run-gnorb (query _server &optional _group)
  "Run the actual search for messages to display. See nnir.el for
some details of how this gets called.

As things stand, the query string can be given as one of two
different things. First is the ID string of an Org heading,
prefixed with \"id+\". This was probably a bad choice as it could
conceivably look like an org tags search string. Fix that later.
If it's an ID, then the entire subtree text of that heading is
scanned for gnus links, and the messages relevant to the subtree
are collected from the registry, and all the resulting messages
are displayed in an ephemeral group.

Otherwise, the query string can be a tags match string, a la the
Org agenda tags search. All headings matched by this string will
be scanned for gnus messages, and those messages displayed."
  (if (cdr-safe (assq 'articles query))
      ;; The work has already been done elsewhere.
      (cdr (assq 'articles query))
    (save-window-excursion
      (let ((q (cdr (assq 'query query)))
	    (buf (get-buffer-create nnir-tmp-buffer))
	    msg-ids org-ids links vectors)
	(with-current-buffer buf
	  (erase-buffer)
	  (setq nngnorb-attachment-file-list nil))
	(when (and (equal "5.13" gnus-version-number) (version< emacs-version "24.4"))
	  (setq q (car q)))
	(cond ((string-match "id\\+\\([[:alnum:]-]+\\)$" q)
	       (with-demoted-errors "Error: %S"
		 (org-id-goto (match-string 1 q))
		 (save-restriction
		   (org-narrow-to-subtree)
		   (append-to-buffer
		    buf
		    (point-min)
		    (point-max))
		   (setq org-ids
			 (append
			  (gnorb-collect-ids)
			  org-ids))
		   (when org-ids
		     (with-current-buffer buf
		       ;; The file list var is buffer local, so set it
		       ;; (local to the nnir-tmp-buffer) to a full list
		       ;; of all files in the subtree.
		       (dolist (id org-ids)
			 (setq nngnorb-attachment-file-list
			       (append (gnorb-org-attachment-list id)
				       nngnorb-attachment-file-list))))))))
	      ((listp q)
	       ;; be a little careful: this could be a list of links, or
	       ;; it could be the full plist
	       (setq links (if (plist-member q :gnus)
			       (plist-get q :gnus)
			     q)))
	      (t (org-map-entries
		  (lambda ()
		    (push (org-id-get) org-ids)
		    (append-to-buffer
		     buf
		     (point)
		     (save-excursion
		       (outline-next-heading)
		       (point))))
		  q
		  'agenda)))
	(with-current-buffer buf
	  (goto-char (point-min))
	  (setq links (append
		       (alist-get 'gnus (gnorb-scan-links (point-max) 'gnus))
		       links))

	  (goto-char (point-min)))
	;; First add all links to messages (elements of messages should
	;; look like (group-name message-id)).
	(dolist (l links)
	  (push (org-link-unescape
		 (nth 1 (split-string l "#")))
		msg-ids))

	(unless (gnus-alive-p)
	  (gnus))

	;; Then use the registry to turn list of org-ids into list of
	;; msg-ids.
	(dolist (i (delq nil (delete-dups org-ids)))
	  (when-let ((rel-msg-id (gnorb-registry-org-id-search i)))
	    (setq msg-ids (append (delq nil rel-msg-id) msg-ids))))

	;; Then find the group and article number for each msg-id, and
	;; push that onto our return value "vectors".
	(when msg-ids
	  (dolist (id (delete-dups msg-ids) (when vectors
					      (nreverse vectors)))
	    (pcase-let ((`(,group . ,artno) (gnorb-msg-id-request-head id)))
	      (when (and artno (integerp artno) (> artno 0))
		(push (vector group artno 100) vectors)))))))))

(defvar gnorb-summary-minor-mode-map (make-sparse-keymap)
  "Keymap for use in Gnorb's *Summary* minor mode.")

(define-minor-mode gnorb-summary-minor-mode
  "A minor mode for use in nnir *Summary* buffers created by Gnorb.

These *Summary* buffers are usually created by calling
`gnorb-org-view', or by initiating an nnir search on a nngnorb server.

While active, this mode provides some Gnorb-specific commands,
and also advises Gnus' reply-related commands in order to
continue to provide tracking of sent messages."
  nil " Gnorb" gnorb-summary-minor-mode-map
  (setq nngnorb-attachment-file-list
	;; Copy the list of attached files from the nnir-tmp-buffer to
	;; this summary buffer.
	(buffer-local-value
	 'nngnorb-attachment-file-list
	  (get-buffer-create nnir-tmp-buffer))))

(define-key gnorb-summary-minor-mode-map
  [remap gnus-summary-exit]
  'gnorb-summary-exit)

(define-key gnorb-summary-minor-mode-map (kbd "C-c d")
  'gnorb-summary-disassociate-message)

;; All this is pretty horrible, but it's the only way to get sane
;; behavior, there are no appropriate hooks, and I want to avoid
;; advising functions.

(define-key gnorb-summary-minor-mode-map
  [remap gnus-summary-very-wide-reply-with-original]
  'gnorb-summary-very-wide-reply-with-original)

(define-key gnorb-summary-minor-mode-map
  [remap gnus-summary-wide-reply-with-original]
  'gnorb-summary-wide-reply-with-original)

(define-key gnorb-summary-minor-mode-map
  [remap gnus-summary-reply]
  'gnorb-summary-reply)

(define-key gnorb-summary-minor-mode-map
  [remap gnus-summary-very-wide-reply]
  'gnorb-summary-very-wide-reply)

(define-key gnorb-summary-minor-mode-map
  [remap gnus-summary-reply-with-original]
  'gnorb-summary-reply-with-original)

(define-key gnorb-summary-minor-mode-map
  [remap gnus-summary-wide-reply]
  'gnorb-summary-wide-reply)

(define-key gnorb-summary-minor-mode-map
  [remap gnus-summary-mail-forward]
  'gnorb-summary-mail-forward)

(defun gnorb-summary-wide-reply (&optional yank)
  (interactive
   (list (and current-prefix-arg
	      (gnus-summary-work-articles 1))))
  (gnorb-summary-reply yank t))

(defun gnorb-summary-reply-with-original (n &optional wide)
  (interactive "P")
  (gnorb-summary-reply (gnus-summary-work-articles n) wide))

(defun gnorb-summary-very-wide-reply (&optional yank)
  (interactive
   (list (and current-prefix-arg
	      (gnus-summary-work-articles 1))))
  (gnorb-summary-reply yank t (gnus-summary-work-articles yank)))

(defun gnorb-summary-reply (&optional yank wide very-wide)
  (interactive)
  (gnus-summary-reply yank wide very-wide)
  (gnorb-summary-reply-hook))

(defun gnorb-summary-wide-reply-with-original (n)
  (interactive "P")
  (gnorb-summary-reply-with-original n t))

(defun gnorb-summary-very-wide-reply-with-original (n)
  (interactive "P")
  (gnorb-summary-reply
   (gnus-summary-work-articles n) t (gnus-summary-work-articles n)))

(defun gnorb-summary-mail-forward (n)
  (interactive "P")
  (gnus-summary-mail-forward n t)
  (gnorb-summary-reply-hook))

(defun gnorb-summary-reply-hook (&rest _args)
  "Function that runs after any command that creates a reply."
  ;; Not actually a "hook"
  (let* ((msg-id (if message-reply-headers
		     (aref message-reply-headers 4)
		   ;; When forwarding messages,
		   ;; `message-reply-headers' is nil.
		   (save-excursion
		     (let ((case-fold-search t))
		       (when (re-search-forward "message-id: +\\(.*\\)$" (point-max) t)
			 (match-string 1))))))
	 (org-id (car-safe (gnus-registry-get-id-key msg-id 'gnorb-ids)))
	 (compose-marker (make-marker))
	 (attachments (buffer-local-value
		       'nngnorb-attachment-file-list
		       (get-buffer nnir-tmp-buffer))))
    (when org-id
      (move-marker compose-marker (point))
      (save-restriction
	(widen)
	(message-narrow-to-headers-or-head)
	(goto-char (point-at-bol))
	(open-line 1)
	(message-insert-header
	 (intern gnorb-mail-header)
	 org-id)
	;; As with elsewhere, this should be redundant with
	;; `gnorb-gnus-check-outgoing-headers.'  Even if not, it
	;; should be switched to use `message-send-actions'
	;; (add-to-list 'message-exit-actions
	;; 'gnorb-org-restore-after-send t)
	)
      (goto-char compose-marker))
    (when attachments
      (map-y-or-n-p
       (lambda (a) (format "Attach %s to outgoing message? "
			   (file-name-nondirectory a)))
       (lambda (a)
	 (mml-attach-file a (mm-default-file-encoding a)
			  nil "attachment"))
       attachments
       '("file" "files" "attach")))))

(defun gnorb-summary-exit ()
  "Like `gnus-summary-exit', but restores the gnorb window conf."
  (interactive)
  (call-interactively 'gnus-summary-exit)
  (gnorb-restore-layout))

(defun gnorb-summary-disassociate-message ()
  "Disassociate a message from its Org TODO.

This is used in a Gnorb-created *Summary* buffer to remove the
connection between the message and whichever Org TODO resulted in
the message being included in this search."
  (interactive)
  (unless (get-buffer-window gnus-article-buffer t)
    (gnus-summary-display-article
     (gnus-summary-article-number)))
  (let* ((msg-id (gnus-fetch-original-field "message-id"))
	 (org-ids (gnus-registry-get-id-key msg-id 'gnorb-ids))
	 chosen multiple-alist)
    (if org-ids
	(progn
	  (if (= (length org-ids) 1)
	      ;; Only one associated Org TODO.
	      (progn (gnus-registry-set-id-key msg-id 'gnorb-ids nil)
		     (setq chosen (car org-ids)))
	    ;; Multiple associated TODOs, prompt to choose one.
	    (setq multiple-alist
		  (mapcar
		   (lambda (h)
		     (cons (gnorb-pretty-outline h) h))
		   org-ids))
	    (setq chosen
		  (cdr
		   (assoc
		    (org-completing-read
		     "Choose a TODO to disassociate from: "
		     multiple-alist)
		    multiple-alist)))
	    (gnus-registry-set-id-key msg-id 'gnorb-ids
				      (remove chosen org-ids)))
	  (message "Message disassociated from %s"
		   (gnorb-pretty-outline chosen)))
      (message "Message has no associations"))))

(defvar nngnorb-status-string "")

(defun nngnorb-retrieve-headers (_articles &optional _group _server _fetch-old)
  (with-current-buffer nntp-server-buffer
    (erase-buffer))
  'nov)

(defun nngnorb-open-server (_server &optional _definitions)
  t)

(defun nngnorb-close-server (&optional _server)
  t)

(defun nngnorb-request-close ()
  t)

(defun nngnorb-server-opened (&optional _server)
  t)

(defun nngnorb-status-message (&optional _server)
  nngnorb-status-string)

(defun nngnorb-request-article (_article &optional _group _server _to-buffer)
  (setq nngnorb-status-string "No such group")
  nil)

(defun nngnorb-request-group (_group &optional _server _fast _info)
  (let (deactivate-mark)
    (with-current-buffer nntp-server-buffer
      (erase-buffer)
      (insert "411 no such news group\n")))
  (setq nngnorb-status-string "No such group")
  nil)

(defun nngnorb-close-group (_group &optional _server)
  t)

(defun nngnorb-request-list (&optional _server)
  (with-current-buffer nntp-server-buffer
    (erase-buffer))
  t)

(defun nngnorb-request-post (&optional _server)
  (setq nngnorb-status-string "Read-only server")
  nil)

(provide 'nngnorb)

;;; nnnil.el ends here
