# History graph rendering for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Restyles the commit graph that _repo__show_log prints. Event commits become
# one line: an event glyph in place of the graph node, the change ID, and a
# short label. Bookmarks and tags of every commit follow its description.
#
# Public surface:
#   _log__render — restyle a _repo__show_log graph read from stdin

# Usage: _log__render ICONS COLOR
#
# Reads a graph in the _repo__show_log format from stdin and prints it
# restyled. ICONS selects the glyph set: 'nerd' for Nerd Font icons or
# 'unicode' for standard Unicode symbols. COLOR is 'true' or 'false' and
# selects whether ANSI styling is emitted.
#
# An event line shows the glyph for its operation, the change ID and a label:
#   create, delete, fork, checkin, move, remove, rename: the task name
#   context:add, context:delete: the context name
#   checkpoint: the checkpoint message
# Task and context names drop the ID prefix and the hex suffix.
_log__render() {
  local icons="$1" color="$2"
  awk -v icons="$icons" -v color="$color" '
    BEGIN {
      RS_CHAR = "\036"; US_CHAR = "\037"; GS_CHAR = "\035"; NODE_CHAR = "\001"
      nerd = (icons == "nerd")

      # Event key, Nerd Font glyph, Unicode glyph, ANSI color.
      define("new",        "\357\200\205", "\342\230\205", "1;35")  # star
      define("create",     "\357\201\247", "+",            "1;32")  # plus
      define("fork",       "\357\204\246", "\342\221\202", "1;36")  # code fork
      define("edit",       "\357\201\200", "\342\234\216", "33")    # pencil
      define("checkout",   "\357\201\213", "\342\226\266", "34")    # play
      define("checkpoint", "\357\200\244", "\342\232\221", "37")    # flag
      define("complete",   "\357\200\214", "\342\234\223", "1;32")  # check
      define("handoff",    "\357\202\213", "\342\206\227", "36")    # sign out
      define("checkin",    "\357\220\231", "\342\212\225", "1;36")  # git merge
      define("propagate",  "\357\220\231", "\342\207\243", "36")    # git merge
      define("publish",    "\357\204\265", "\342\207\252", "1;35")  # rocket
      define("delete",     "\357\207\270", "\342\234\227", "31")    # trash
      define("reorder",    "\357\203\234", "\342\207\205", "33")    # sort
      define("context",    "\357\203\206", "\302\247",     "33")    # paperclip
      define("init",       "\357\200\225", "\342\227\216", "1;35")  # home
      define("move",       "\357\203\254", "\342\207\204", "33")    # exchange
      define("remove",     "\357\201\250", "\342\210\222", "31")    # minus
      define("rename",     "\357\211\206", "\342\234\220", "33")    # text cursor
      define("unknown",    "\357\201\231", "?",            "0")     # question

      BOOKMARK_ICON = nerd ? "\357\221\241" : "\342\232\220"
      TAG_ICON      = nerd ? "\357\200\253" : "\342\214\226"
      WARNING_ICON  = nerd ? "\357\201\261" : "\342\232\240"
    }

    function define(key, nerd_glyph, unicode_glyph, code) {
      GLYPH[key] = nerd ? nerd_glyph : unicode_glyph
      GLYPH_COLOR[key] = code
    }

    function style(code, text) {
      return color == "true" ? "\033[" code "m" text "\033[0m" : text
    }

    function strip_ansi(text) {
      gsub(/\033\[[0-9;]*m/, "", text)
      return text
    }

    function short_name(id) {
      sub(/^.*\//, "", id)
      sub(/\.md$/, "", id)
      sub(/-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$/, "", id)
      return id
    }

    function render_refs(list, icon, code, weight,    out, n, i, names, ref_icon, ref_code) {
      out = ""
      n = split(list, names, " ")
      for (i = 1; i <= n; i++) {
        ref_icon = icon; ref_code = code
        if (names[i] ~ /\?\?$/) { ref_icon = WARNING_ICON; ref_code = "31" }
        if (color == "true") {
          out = out "  \033[" weight ";" ref_code "m" ref_icon " \033[0;" weight ";" code "m" names[i] "\033[0m"
        } else {
          out = out "  " ref_icon " " names[i]
        }
      }
      return out
    }

    # Renders the four ref fields starting at fields[first].
    function render_all_refs(fields, first) {
      return render_refs(fields[first],     BOOKMARK_ICON, "35", "1") \
             render_refs(fields[first + 1], BOOKMARK_ICON, "35", "2") \
             render_refs(fields[first + 2], TAG_ICON,      "33", "1") \
             render_refs(fields[first + 3], TAG_ICON,      "33", "2")
    }

    function render_event(line,    at, prefix, f, message, close_at, tag, rest, namespace, entity, operation, key, label, glyph, node_at, files) {
      at = index(line, RS_CHAR)
      prefix = substr(line, 1, at - 1)
      split(strip_ansi(substr(line, at + 1)), f, US_CHAR)
      message = f[8]

      namespace = ""; entity = ""; operation = ""; rest = message
      close_at = index(message, "]")
      if (substr(message, 1, 4) == "[tt:" && close_at > 0) {
        tag = substr(message, 5, close_at - 5)
        rest = substr(message, close_at + 1)
        sub(/^ /, "", rest)
        namespace = tag; sub(/:.*$/, "", namespace)
        tag = substr(tag, length(namespace) + 2)
        if (index(tag, ":") > 0) {
          entity = tag; sub(/:.*$/, "", entity)
          operation = substr(tag, length(entity) + 2)
        } else {
          operation = tag
        }
      }

      key = operation
      if (key ~ /^context:/) key = "context"
      if (namespace == "workspace" && operation == "init") key = "init"
      if (!(key in GLYPH)) key = "unknown"

      label = ""
      if (key ~ /^(create|delete|fork|checkin|move|remove|rename)$/) {
        label = style("2", short_name(entity))
      } else if (key == "context") {
        files = f[3]; sub(/ .*$/, "", files)
        label = style("2", short_name(files))
      } else if (key == "checkpoint") {
        label = rest
      }

      glyph = style(GLYPH_COLOR[key], GLYPH[key])
      node_at = index(prefix, NODE_CHAR)
      if (node_at > 0) {
        prefix = substr(prefix, 1, node_at - 1) glyph substr(prefix, node_at + 1)
      }

      if (color == "true") {
        line = prefix "\033[1;2;90m" f[1] "\033[0;2;90m" f[2] "\033[0m"
      } else {
        line = prefix f[1] f[2]
      }
      if (label != "") line = line "  " label
      return line render_all_refs(f, 4)
    }

    function render_plain(line,    at, f) {
      at = index(line, GS_CHAR)
      split(strip_ansi(substr(line, at + 1)), f, US_CHAR)
      return substr(line, 1, at - 1) (color == "true" ? "\033[0m" : "") render_all_refs(f, 1)
    }

    {
      if (index($0, RS_CHAR) > 0) print render_event($0)
      else if (index($0, GS_CHAR) > 0) print render_plain($0)
      else print
    }
  '
}
