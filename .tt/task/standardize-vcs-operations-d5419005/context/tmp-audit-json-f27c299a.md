---
title: "/tmp/audit.json"
created: 2026-08-28T14:09:10Z
updated: 2026-08-28T14:09:10Z
---
{
 "scripts": {
  "scripts/cli/task/changelog": {
   "direct": {
    "log": [
     356
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "_full_range_creation_boundary",
     "_full_range_query_waypoints",
     "_full_range_resolve_commit",
     "_full_range_symlink_diff",
     "count_revs_in_revset",
     "find_parent_branch",
     "get_full_task_range_records",
     "mainline_commit_records",
     "resolve_current",
     "resolve_task_fork_point"
    ]
   },
   "fns": [
    "_full_range_bookmark_task_file",
    "_full_range_covered_by",
    "_full_range_creation_boundary",
    "_full_range_parse_symlink_added",
    "_full_range_parse_symlink_removed",
    "_full_range_query_waypoints",
    "_full_range_resolve_commit",
    "_full_range_span_empty",
    "_full_range_symlink_diff",
    "count_revs_in_revset",
    "find_parent_branch",
    "find_repo_root",
    "get_full_task_range_records",
    "get_project_prefix",
    "get_task_prefix",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "mainline_commit_records",
    "parse_commit_message",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_task_fork_point",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/task/checkin": {
   "direct": {
    "bookmark set": [
     485
    ],
    "commit": [
     461
    ],
    "describe": [
     484
    ],
    "diff": [
     331
    ],
    "log": [
     463
    ],
    "new": [
     400,
     474,
     488
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "find_parent_branch",
     "get_worktree_current_rev",
     "has_conflicts",
     "resolve_current"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ],
    "workspace forget": [
     "forget_worktree"
    ],
    "workspace list": [
     "jj_workspace_list"
    ],
    "workspace root": [
     "resolve_current_worktree"
    ]
   },
   "fns": [
    "_insert_frontmatter_line",
    "append_frontmatter_context",
    "assert_bookmark_up_to_date",
    "collect_descendant_task_dirs",
    "find_parent_branch",
    "find_repo_root",
    "find_worktrees_for_branch",
    "forget_worktree",
    "format_commit_message",
    "generate_hex",
    "generate_timestamp",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "get_workspace_dir",
    "get_worktree_current_rev",
    "has_conflicts",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "make_absolute_symlink",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "parse_workspace_list_line",
    "perform_workspace_switch",
    "prompt",
    "prompt_raw",
    "resolve_canonical_repo",
    "resolve_canonical_repo_path",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_current_worktree",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_task_worktree",
    "resolve_workspace_name",
    "run_hook",
    "status_to_checkbox",
    "task_context_path",
    "task_dir_path",
    "task_file_path",
    "task_root_path",
    "title_to_slug",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction",
    "update_head_symlink",
    "write_context_file",
    "write_task_file"
   ]
  },
  "scripts/cli/task/checkout": {
   "direct": {
    "bookmark set": [
     365
    ],
    "describe": [
     364
    ],
    "new": [
     333,
     336,
     366
    ],
    "workspace add": [
     324
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "find_parent_branch",
     "resolve_current"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ],
    "workspace list": [
     "jj_workspace_list"
    ],
    "workspace root": [
     "resolve_current_worktree"
    ]
   },
   "fns": [
    "find_parent_branch",
    "find_repo_root",
    "find_worktrees_for_branch",
    "format_commit_message",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "get_workspace_dir",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "make_absolute_symlink",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "parse_workspace_list_line",
    "perform_workspace_switch",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_current_worktree",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "run_hook",
    "set_workspace_dir",
    "task_file_path",
    "task_root_path",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction",
    "update_head_symlink"
   ]
  },
  "scripts/cli/task/checkpoint": {
   "direct": {
    "bookmark set": [
     182
    ],
    "commit": [
     171,
     174
    ],
    "log": [
     179
    ],
    "new": [
     168
    ],
    "squash": [
     163
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "count_revs_in_revset",
     "get_commit_description",
     "resolve_current"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ],
    "workspace root": [
     "resolve_current_worktree"
    ]
   },
   "fns": [
    "count_revs_in_revset",
    "find_repo_root",
    "format_commit_message",
    "get_commit_description",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "get_workspace_dir",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "prompt",
    "prompt_raw",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_worktree",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "run_hook",
    "task_file_path",
    "task_root_path",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction"
   ]
  },
  "scripts/cli/task/complete": {
   "direct": {
    "bookmark set": [
     187
    ],
    "commit": [
     186
    ],
    "log": [
     126,
     190
    ],
    "new": [
     171,
     205,
     207
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "get_worktree_current_rev",
     "resolve_current"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ],
    "workspace list": [
     "jj_workspace_list"
    ],
    "workspace root": [
     "resolve_current_worktree"
    ]
   },
   "fns": [
    "find_repo_root",
    "find_worktrees_for_branch",
    "format_commit_message",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "get_workspace_dir",
    "get_worktree_current_rev",
    "is_task_branch",
    "jj_show_at_revision",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "parse_repeated_frontmatter_field",
    "parse_workspace_list_line",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_current_worktree",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_task_worktree",
    "run_hook",
    "task_file_path",
    "task_root_path",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction"
   ]
  },
  "scripts/cli/task/context/add": {
   "direct": {},
   "transitive": {
    "bookmark set": [
     "write_and_commit_on_branch"
    ],
    "commit": [
     "write_and_commit_on_branch"
    ],
    "edit": [
     "write_and_commit_on_branch"
    ],
    "log": [
     "resolve_current",
     "write_and_commit_on_branch"
    ],
    "new": [
     "write_and_commit_on_branch"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ],
    "workspace list": [
     "jj_workspace_list"
    ],
    "workspace root": [
     "resolve_current_worktree"
    ]
   },
   "fns": [
    "_insert_frontmatter_line",
    "append_frontmatter_context",
    "find_repo_root",
    "find_worktrees_for_branch",
    "format_commit_message",
    "generate_hex",
    "generate_timestamp",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "get_workspace_dir",
    "is_task_branch",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "parse_workspace_list_line",
    "prompt_raw",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_current_worktree",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_task_worktree",
    "task_context_path",
    "task_file_path",
    "task_root_path",
    "title_to_slug",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction",
    "update_frontmatter_timestamp",
    "write_and_commit_on_branch",
    "write_context_file",
    "write_task_file"
   ]
  },
  "scripts/cli/task/context/delete": {
   "direct": {},
   "transitive": {
    "bookmark set": [
     "write_and_commit_on_branch"
    ],
    "commit": [
     "write_and_commit_on_branch"
    ],
    "edit": [
     "write_and_commit_on_branch"
    ],
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "resolve_current",
     "write_and_commit_on_branch"
    ],
    "new": [
     "write_and_commit_on_branch"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ],
    "workspace list": [
     "jj_workspace_list"
    ],
    "workspace root": [
     "resolve_current_worktree"
    ]
   },
   "fns": [
    "find_repo_root",
    "find_worktrees_for_branch",
    "format_commit_message",
    "generate_timestamp",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "is_task_branch",
    "jj_show_at_revision",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "parse_workspace_list_line",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_current_worktree",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_task_worktree",
    "task_context_path",
    "task_file_path",
    "task_root_path",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction",
    "write_and_commit_on_branch"
   ]
  },
  "scripts/cli/task/context/get": {
   "direct": {},
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "find_branch_for_task",
     "resolve_current"
    ]
   },
   "fns": [
    "find_branch_for_task",
    "find_repo_root",
    "get_project_prefix",
    "get_task_prefix",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_path_symlinks",
    "resolve_repo",
    "task_context_path",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/task/context/list": {
   "direct": {},
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "find_branch_for_task",
     "resolve_current"
    ]
   },
   "fns": [
    "find_branch_for_task",
    "find_repo_root",
    "get_project_prefix",
    "get_task_prefix",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_path_symlinks",
    "resolve_repo",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/task/create": {
   "direct": {
    "bookmark set": [
     411,
     413,
     431,
     433,
     445
    ],
    "describe": [
     410,
     430,
     443
    ],
    "edit": [
     486
    ],
    "log": [
     107,
     278,
     283,
     381,
     399
    ],
    "new": [
     402,
     412,
     432,
     444,
     484
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "get_worktree_current_rev",
     "resolve_current"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ]
   },
   "fns": [
    "_insert_frontmatter_line",
    "append_frontmatter_subtask",
    "find_repo_root",
    "format_commit_message",
    "generate_hex",
    "generate_timestamp",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "get_worktree_current_rev",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "prompt_raw",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "task_dir_path",
    "task_file_path",
    "task_root_path",
    "title_to_slug",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction",
    "write_task_file",
    "write_task_stub"
   ]
  },
  "scripts/cli/task/current": {
   "direct": {},
   "transitive": {
    "log": [
     "resolve_current"
    ]
   },
   "fns": [
    "find_repo_root",
    "get_project_prefix",
    "get_task_prefix",
    "is_task_branch",
    "log",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_path_symlinks",
    "resolve_repo",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/task/delete": {
   "direct": {
    "bookmark delete": [
     326
    ],
    "bookmark set": [
     318
    ],
    "commit": [
     317
    ],
    "log": [
     325
    ],
    "new": [
     272,
     319
    ],
    "workspace forget": [
     339
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "find_parent_branch",
     "resolve_current"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ],
    "workspace list": [
     "jj_workspace_list"
    ],
    "workspace root": [
     "resolve_current_worktree"
    ]
   },
   "fns": [
    "find_parent_branch",
    "find_repo_root",
    "find_worktrees_for_branch",
    "format_commit_message",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "get_workspace_dir",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "parse_repeated_frontmatter_field",
    "parse_workspace_list_line",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_current_worktree",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_workspace_name",
    "run_hook",
    "task_dir_path",
    "task_file_path",
    "task_root_path",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction"
   ]
  },
  "scripts/cli/task/diff": {
   "direct": {
    "diff": [
     96
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "_full_range_creation_boundary",
     "_full_range_query_waypoints",
     "_full_range_resolve_commit",
     "_full_range_symlink_diff",
     "count_revs_in_revset",
     "find_parent_branch",
     "get_full_task_range_records",
     "get_task_range_context",
     "resolve_current",
     "resolve_task_fork_point"
    ]
   },
   "fns": [
    "_full_range_bookmark_task_file",
    "_full_range_covered_by",
    "_full_range_creation_boundary",
    "_full_range_parse_symlink_added",
    "_full_range_parse_symlink_removed",
    "_full_range_query_waypoints",
    "_full_range_resolve_commit",
    "_full_range_span_empty",
    "_full_range_symlink_diff",
    "count_revs_in_revset",
    "find_parent_branch",
    "find_repo_root",
    "get_full_task_range_records",
    "get_project_prefix",
    "get_task_prefix",
    "get_task_range_context",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "metadata_exclusion_fileset",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_task_fork_point",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/task/edit": {
   "direct": {},
   "transitive": {
    "bookmark set": [
     "write_and_commit_on_branch"
    ],
    "commit": [
     "write_and_commit_on_branch"
    ],
    "edit": [
     "write_and_commit_on_branch"
    ],
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "resolve_current",
     "write_and_commit_on_branch"
    ],
    "new": [
     "write_and_commit_on_branch"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ],
    "workspace list": [
     "jj_workspace_list"
    ],
    "workspace root": [
     "resolve_current_worktree"
    ]
   },
   "fns": [
    "find_repo_root",
    "find_worktrees_for_branch",
    "format_commit_message",
    "generate_timestamp",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "is_task_branch",
    "jj_show_at_revision",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "parse_body",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "parse_repeated_frontmatter_field",
    "parse_task_frontmatter",
    "parse_workspace_list_line",
    "prompt",
    "prompt_raw",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_current_worktree",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_task_worktree",
    "task_file_path",
    "task_root_path",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction",
    "write_and_commit_on_branch",
    "write_task_file"
   ]
  },
  "scripts/cli/task/move": {
   "direct": {
    "bookmark set": [
     256,
     283
    ],
    "describe": [
     255,
     282
    ],
    "log": [
     201,
     292
    ],
    "new": [
     241,
     257,
     263,
     284,
     311,
     314
    ],
    "rebase": [
     298
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "find_parent_branch",
     "get_worktree_current_rev",
     "resolve_current"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ]
   },
   "fns": [
    "_insert_frontmatter_line",
    "append_frontmatter_subtask",
    "find_parent_branch",
    "find_repo_root",
    "format_commit_message",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "get_workspace_dir",
    "get_worktree_current_rev",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "task_dir_path",
    "task_file_path",
    "task_root_path",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction"
   ]
  },
  "scripts/cli/task/parent": {
   "direct": {},
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "find_parent_branch",
     "resolve_current"
    ]
   },
   "fns": [
    "find_parent_branch",
    "find_parent_project",
    "find_repo_root",
    "get_project_prefix",
    "get_task_prefix",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_path_symlinks",
    "resolve_repo",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/task/prompt": {
   "direct": {},
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "find_branch_for_task",
     "resolve_current"
    ]
   },
   "fns": [
    "find_branch_for_task",
    "find_repo_root",
    "get_project_prefix",
    "get_task_prefix",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "parse_body",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "resolve_current",
    "resolve_path_symlinks",
    "resolve_repo",
    "task_context_path",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/task/propagate": {
   "direct": {
    "bookmark set": [
     175,
     216
    ],
    "edit": [
     184,
     217,
     387
    ],
    "log": [
     67,
     73,
     85,
     140,
     203,
     206
    ],
    "new": [
     174,
     215
    ],
    "rebase": [
     153
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "get_worktree_current_rev",
     "has_conflicts",
     "resolve_current"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ]
   },
   "fns": [
    "find_repo_root",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "get_worktree_current_rev",
    "has_conflicts",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_repeated_frontmatter_field",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "task_file_path",
    "task_root_path",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction"
   ]
  },
  "scripts/cli/task/publish": {
   "direct": {
    "bookmark set": [
     316
    ],
    "commit": [
     300
    ],
    "describe": [
     315
    ],
    "log": [
     302
    ],
    "new": [
     291,
     305,
     319
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "has_conflicts",
     "resolve_current"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ],
    "workspace list": [
     "jj_workspace_list"
    ],
    "workspace root": [
     "resolve_current_worktree"
    ]
   },
   "fns": [
    "find_repo_root",
    "find_worktrees_for_branch",
    "format_commit_message",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "get_workspace_dir",
    "has_conflicts",
    "is_task_branch",
    "jj_show_at_revision",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "parse_workspace_list_line",
    "prompt",
    "prompt_raw",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_current_worktree",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "task_file_path",
    "task_root_path",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction"
   ]
  },
  "scripts/cli/task/rename": {
   "direct": {
    "bookmark rename": [
     254
    ],
    "bookmark set": [
     246
    ],
    "commit": [
     245
    ],
    "edit": [
     225,
     272
    ],
    "file list": [
     205
    ],
    "log": [
     136,
     194,
     198,
     264,
     267
    ],
    "new": [
     247,
     312
    ],
    "op log": [
     190
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_op",
     "jj_show_at_revision"
    ],
    "log": [
     "find_parent_branch",
     "resolve_current"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ]
   },
   "fns": [
    "find_parent_branch",
    "find_repo_root",
    "format_commit_message",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_op",
    "jj_show_at_revision",
    "log",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "task_dir_path",
    "task_file_path",
    "task_root_path",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction"
   ]
  },
  "scripts/cli/task/reorder": {
   "direct": {
    "bookmark set": [
     263,
     363
    ],
    "commit": [
     262,
     362
    ],
    "new": [
     253,
     354
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "find_branch_for_task",
     "find_parent_branch",
     "resolve_current"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ],
    "workspace list": [
     "jj_workspace_list"
    ],
    "workspace root": [
     "resolve_current_worktree"
    ]
   },
   "fns": [
    "find_branch_for_task",
    "find_parent_branch",
    "find_repo_root",
    "find_worktrees_for_branch",
    "format_commit_message",
    "generate_timestamp",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "parse_body",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "parse_repeated_frontmatter_field",
    "parse_task_frontmatter",
    "parse_workspace_list_line",
    "resolve_canonical_repo",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_current_worktree",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_task_worktree",
    "task_file_path",
    "task_root_path",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction",
    "write_task_file"
   ]
  },
  "scripts/cli/task/revset": {
   "direct": {
    "log": [
     56,
     60,
     123
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "_full_range_creation_boundary",
     "_full_range_query_waypoints",
     "_full_range_resolve_commit",
     "_full_range_symlink_diff",
     "count_revs_in_revset",
     "find_parent_branch",
     "get_full_task_range_records",
     "get_task_range_context",
     "resolve_current",
     "resolve_task_fork_point"
    ]
   },
   "fns": [
    "_full_range_bookmark_task_file",
    "_full_range_covered_by",
    "_full_range_creation_boundary",
    "_full_range_parse_symlink_added",
    "_full_range_parse_symlink_removed",
    "_full_range_query_waypoints",
    "_full_range_resolve_commit",
    "_full_range_span_empty",
    "_full_range_symlink_diff",
    "count_revs_in_revset",
    "find_parent_branch",
    "find_repo_root",
    "get_full_task_range_records",
    "get_project_prefix",
    "get_task_prefix",
    "get_task_range_context",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_task_fork_point",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/task/select": {
   "direct": {
    "log": [
     62
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ]
   },
   "fns": [
    "_select_value",
    "find_repo_root",
    "get_project_prefix",
    "get_task_prefix",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "resolve_path_symlinks",
    "resolve_repo",
    "select_value",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/task/show": {
   "direct": {},
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "find_branch_for_task",
     "find_parent_branch",
     "resolve_current"
    ],
    "workspace list": [
     "jj_workspace_list"
    ]
   },
   "fns": [
    "find_branch_for_task",
    "find_parent_branch",
    "find_repo_root",
    "find_worktrees_for_branch",
    "get_project_prefix",
    "get_task_prefix",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "parse_body",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_quoted_frontmatter_field",
    "parse_workspace_list_line",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_path_symlinks",
    "resolve_repo",
    "status_to_checkbox",
    "task_context_path",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/task/tree": {
   "direct": {
    "log": [
     323
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "resolve_current"
    ]
   },
   "fns": [
    "find_repo_root",
    "get_project_prefix",
    "get_task_prefix",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "log",
    "parse_frontmatter_fields",
    "parse_repeated_frontmatter_field",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_path_symlinks",
    "resolve_repo",
    "status_to_checkbox",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/workspace/init": {
   "direct": {
    "commit": [
     223
    ]
   },
   "transitive": {},
   "fns": [
    "format_commit_message",
    "init_tt_history",
    "log",
    "make_absolute_symlink",
    "resolve_path_symlinks",
    "set_workspace_dir",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/workspace/repo": {
   "direct": {},
   "transitive": {},
   "fns": [
    "find_repo_root",
    "log",
    "resolve_canonical_repo",
    "resolve_path_symlinks",
    "resolve_repo"
   ]
  },
  "scripts/cli/workspace/root": {
   "direct": {},
   "transitive": {},
   "fns": [
    "find_repo_root",
    "get_workspace_dir",
    "log",
    "resolve_path_symlinks",
    "resolve_repo",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/worktree/active": {
   "direct": {},
   "transitive": {},
   "fns": [
    "find_repo_root",
    "get_active_worktree",
    "get_workspace_dir",
    "log",
    "resolve_path_symlinks",
    "resolve_repo",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/worktree/delete": {
   "direct": {
    "workspace root": [
     111
    ]
   },
   "transitive": {
    "file show": [
     "jj_show_at_revision"
    ],
    "log": [
     "resolve_current"
    ],
    "op log": [
     "get_jj_op_id"
    ],
    "op restore": [
     "tt_rollback_transaction"
    ],
    "workspace forget": [
     "forget_worktree"
    ],
    "workspace list": [
     "jj_workspace_list"
    ]
   },
   "fns": [
    "find_repo_root",
    "forget_worktree",
    "get_active_worktree",
    "get_jj_op_id",
    "get_project_prefix",
    "get_task_prefix",
    "get_workspace_dir",
    "is_project_branch",
    "is_task_branch",
    "jj_show_at_revision",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "make_absolute_symlink",
    "parse_frontmatter_field",
    "parse_frontmatter_fields",
    "parse_workspace_list_line",
    "resolve_canonical_repo",
    "resolve_canonical_repo_path",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_workspace_name",
    "task_file_path",
    "task_root_path",
    "tt_begin_transaction",
    "tt_commit_transaction",
    "tt_metadata_path",
    "tt_rollback_transaction",
    "update_head_symlink"
   ]
  },
  "scripts/cli/worktree/list": {
   "direct": {},
   "transitive": {
    "log": [
     "resolve_current"
    ],
    "workspace list": [
     "jj_workspace_list"
    ],
    "workspace root": [
     "resolve_current_worktree"
    ]
   },
   "fns": [
    "find_repo_root",
    "get_project_prefix",
    "get_task_prefix",
    "is_task_branch",
    "jj_workspace_list",
    "list_workspaces",
    "list_worktree_entries",
    "log",
    "parse_workspace_list_line",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_current_worktree",
    "resolve_path_symlinks",
    "resolve_repo",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/worktree/show": {
   "direct": {},
   "transitive": {
    "workspace list": [
     "jj_workspace_list"
    ]
   },
   "fns": [
    "find_repo_root",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "parse_workspace_list_line",
    "resolve_canonical_repo",
    "resolve_canonical_repo_path",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_workspace_path"
   ]
  },
  "scripts/cli/worktree/switch": {
   "direct": {
    "workspace root": [
     80
    ]
   },
   "transitive": {
    "log": [
     "resolve_current"
    ],
    "workspace list": [
     "jj_workspace_list"
    ]
   },
   "fns": [
    "find_repo_root",
    "get_active_worktree",
    "get_project_prefix",
    "get_task_prefix",
    "get_workspace_dir",
    "is_task_branch",
    "jj_workspace_list",
    "list_worktree_entries",
    "log",
    "make_absolute_symlink",
    "parse_workspace_list_line",
    "perform_workspace_switch",
    "resolve_current",
    "resolve_current_bookmark",
    "resolve_path_symlinks",
    "resolve_repo",
    "resolve_workspace_name",
    "run_hook",
    "task_file_path",
    "task_root_path",
    "tt_metadata_path",
    "update_head_symlink"
   ]
  },
  "scripts/cli/history/undo": {
   "direct": {
    "op restore": [
     162,
     166
    ]
   },
   "transitive": {
    "op log": [
     "get_jj_op_id"
    ]
   },
   "fns": [
    "find_repo_root",
    "get_jj_op_id",
    "log",
    "resolve_canonical_repo",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/history/unlock": {
   "direct": {},
   "transitive": {
    "op log": [
     "get_jj_op_id"
    ]
   },
   "fns": [
    "find_repo_root",
    "get_jj_op_id",
    "log",
    "resolve_canonical_repo",
    "resolve_history_file_location",
    "resolve_path_symlinks",
    "resolve_repo",
    "tt_metadata_path"
   ]
  },
  "scripts/cli/tt": {
   "direct": {},
   "transitive": {},
   "fns": [
    "log",
    "prompt",
    "prompt_raw"
   ]
  }
 },
 "common_funcs": {
  "_full_range_creation_boundary": {
   "log": [
    974
   ]
  },
  "_full_range_query_waypoints": {
   "log": [
    996
   ]
  },
  "_full_range_resolve_commit": {
   "log": [
    947
   ]
  },
  "_full_range_symlink_diff": {
   "log": [
    1006
   ]
  },
  "check_bookmark_up_to_date": {
   "log": [
    1430
   ]
  },
  "count_revs_in_revset": {
   "log": [
    399
   ]
  },
  "find_branch_for_task": {
   "log": [
    1095,
    1118
   ]
  },
  "find_parent_branch": {
   "log": [
    633
   ]
  },
  "forget_worktree": {
   "workspace forget": [
    1418
   ]
  },
  "get_commit_description": {
   "log": [
    406
   ]
  },
  "get_full_task_range_records": {
   "log": [
    919,
    935
   ]
  },
  "get_jj_op_id": {
   "op log": [
    27
   ]
  },
  "get_task_range_context": {
   "log": [
    697
   ]
  },
  "get_worktree_current_rev": {
   "log": [
    1134
   ]
  },
  "has_conflicts": {
   "log": [
    617
   ]
  },
  "is_wc_clean": {
   "log": [
    414
   ]
  },
  "jj_show_at_op": {
   "file show": [
    36
   ]
  },
  "jj_show_at_revision": {
   "file show": [
    14
   ]
  },
  "jj_workspace_list": {
   "workspace list": [
    1187
   ]
  },
  "mainline_commit_records": {
   "log": [
    1057
   ]
  },
  "resolve_current": {
   "log": [
    1305,
    1312
   ]
  },
  "resolve_current_worktree": {
   "workspace root": [
    1141
   ]
  },
  "resolve_task_fork_point": {
   "log": [
    747
   ]
  },
  "tt_rollback_transaction": {
   "op restore": [
    1938
   ]
  },
  "write_and_commit_on_branch": {
   "log": [
    1224
   ],
   "edit": [
    1226
   ],
   "new": [
    1227,
    1233
   ],
   "commit": [
    1231,
    1237
   ],
   "bookmark set": [
    1232,
    1238
   ]
  }
 }
}
