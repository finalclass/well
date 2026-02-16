(* doc_html — Generate static HTML documentation from parsed modules *)

let escape_html s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | '&' -> Buffer.add_string buf "&amp;"
    | '<' -> Buffer.add_string buf "&lt;"
    | '>' -> Buffer.add_string buf "&gt;"
    | '"' -> Buffer.add_string buf "&quot;"
    | _ -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

(* Convert doc text to HTML — handle code blocks {[ ... ]} and paragraphs *)
let doc_to_html doc =
  if doc = "" then ""
  else begin
    let lines = String.split_on_char '\n' doc in
    let buf = Buffer.create 256 in
    let in_code = ref false in
    List.iter (fun line ->
      let trimmed = String.trim line in
      if !in_code then begin
        if trimmed = "]}" || trimmed = "}" then begin
          Buffer.add_string buf "</code></pre>";
          in_code := false
        end else begin
          Buffer.add_string buf (escape_html line);
          Buffer.add_char buf '\n'
        end
      end else if trimmed = "{[" || trimmed = "{" then begin
        Buffer.add_string buf "<pre><code>";
        in_code := true
      end else if trimmed = "" then
        Buffer.add_string buf "<br>"
      else begin
        Buffer.add_string buf (escape_html line);
        Buffer.add_char buf '\n'
      end
    ) lines;
    Buffer.contents buf
  end

let css = {|:root {
  --bg: #fafafa;
  --bg-card: #ffffff;
  --text: #1a1a1a;
  --text-muted: #6b7280;
  --border: #e5e7eb;
  --accent: #2563eb;
  --accent-light: #eff6ff;
  --code-bg: #f3f4f6;
  --tag-get: #059669;
  --tag-post: #d97706;
  --tag-put: #7c3aed;
  --tag-delete: #dc2626;
  --tag-live: #0891b2;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  color: var(--text);
  background: var(--bg);
  line-height: 1.6;
}
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
code, pre {
  font-family: "JetBrains Mono", "Fira Code", "SF Mono", Menlo, monospace;
  font-size: 0.875rem;
}
code {
  background: var(--code-bg);
  padding: 0.125rem 0.375rem;
  border-radius: 4px;
}
pre {
  background: var(--code-bg);
  padding: 1rem;
  border-radius: 8px;
  overflow-x: auto;
  margin: 0.75rem 0;
}
pre code { background: none; padding: 0; }

.layout {
  display: grid;
  grid-template-columns: 240px 1fr;
  min-height: 100vh;
}
.sidebar {
  background: var(--bg-card);
  border-right: 1px solid var(--border);
  padding: 1.5rem 1rem;
  position: sticky;
  top: 0;
  height: 100vh;
  overflow-y: auto;
}
.sidebar h2 {
  font-size: 1.125rem;
  margin-bottom: 1rem;
  padding-bottom: 0.5rem;
  border-bottom: 1px solid var(--border);
}
.sidebar ul { list-style: none; }
.sidebar li { margin-bottom: 0.25rem; }
.sidebar a {
  display: block;
  padding: 0.25rem 0.5rem;
  border-radius: 4px;
  color: var(--text);
  font-size: 0.875rem;
}
.sidebar a:hover { background: var(--accent-light); text-decoration: none; }
.sidebar .section-label {
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  margin-top: 1rem;
  margin-bottom: 0.375rem;
  padding-left: 0.5rem;
}

.content {
  padding: 2rem 3rem;
  max-width: 960px;
}
.content h1 {
  font-size: 1.75rem;
  margin-bottom: 0.5rem;
}
.content h2 {
  font-size: 1.25rem;
  margin-top: 2rem;
  margin-bottom: 0.75rem;
  padding-bottom: 0.375rem;
  border-bottom: 1px solid var(--border);
}
.content h3 {
  font-size: 1rem;
  margin-top: 1.25rem;
  margin-bottom: 0.375rem;
}
.subtitle {
  color: var(--text-muted);
  margin-bottom: 1.5rem;
}

.tag {
  display: inline-block;
  padding: 0.125rem 0.5rem;
  border-radius: 4px;
  font-size: 0.75rem;
  font-weight: 600;
  font-family: monospace;
  color: white;
}
.tag-get { background: var(--tag-get); }
.tag-post { background: var(--tag-post); }
.tag-put { background: var(--tag-put); }
.tag-delete { background: var(--tag-delete); }
.tag-live { background: var(--tag-live); }

table {
  width: 100%;
  border-collapse: collapse;
  margin: 0.75rem 0;
}
th, td {
  text-align: left;
  padding: 0.5rem 0.75rem;
  border-bottom: 1px solid var(--border);
}
th {
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.item {
  margin-bottom: 1.5rem;
  padding: 1rem;
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: 8px;
}
.item-name {
  font-weight: 600;
  font-family: monospace;
  font-size: 0.9375rem;
}
.item-sig {
  color: var(--text-muted);
  font-family: monospace;
  font-size: 0.8125rem;
  margin-top: 0.25rem;
}
.item-doc {
  margin-top: 0.5rem;
  font-size: 0.9375rem;
}
.module-list {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: 0.75rem;
  margin: 0.75rem 0;
}
.module-card {
  padding: 0.75rem 1rem;
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: 8px;
}
.module-card:hover { border-color: var(--accent); }
.module-card .name { font-weight: 600; }
.module-card .path {
  font-size: 0.75rem;
  color: var(--text-muted);
  font-family: monospace;
}
.empty { color: var(--text-muted); font-style: italic; }

@media (max-width: 768px) {
  .layout { grid-template-columns: 1fr; }
  .sidebar {
    position: static;
    height: auto;
    border-right: none;
    border-bottom: 1px solid var(--border);
  }
  .content { padding: 1.5rem 1rem; }
}
|}

let method_tag meth =
  let cls, label = match meth with
    | Doc_parser.Get -> "tag-get", "GET"
    | Doc_parser.Post -> "tag-post", "POST"
    | Doc_parser.Put -> "tag-put", "PUT"
    | Doc_parser.Delete -> "tag-delete", "DELETE"
  in
  Printf.sprintf {|<span class="tag %s">%s</span>|} cls label

let page_wrapper ~title ~sidebar_html ~content_html =
  Printf.sprintf
    {|<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>%s</title>
  <link rel="stylesheet" href="%sstyle.css">
</head>
<body>
<div class="layout">
  <nav class="sidebar">
    %s
  </nav>
  <main class="content">
    %s
  </main>
</div>
</body>
</html>|}
    (escape_html title)
    (if String.contains title '/' then "../" else "")
    sidebar_html
    content_html

(* Collect all routes across modules *)
let collect_routes modules =
  List.concat_map (fun (m : Doc_parser.module_doc) ->
    List.filter_map (fun (item : Doc_parser.doc_item) ->
      match item.kind with
      | Route (meth, path) -> Some (meth, path, m.name, item.doc, item.line)
      | _ -> None
    ) m.items
  ) modules

(* Collect all LiveViews *)
let collect_liveviews modules =
  List.concat_map (fun (m : Doc_parser.module_doc) ->
    List.filter_map (fun (item : Doc_parser.doc_item) ->
      match item.kind with
      | LiveView path -> Some (path, m.name, item.doc)
      | _ -> None
    ) m.items
  ) modules

(* Build sidebar HTML *)
let sidebar_html ~project_name ~modules ~is_subpage =
  let prefix = if is_subpage then "../" else "" in
  let buf = Buffer.create 512 in
  Buffer.add_string buf (Printf.sprintf {|<h2><a href="%sindex.html">%s</a></h2>|}
                           prefix (escape_html project_name));
  Buffer.add_string buf {|<div class="section-label">Overview</div><ul>|};
  Buffer.add_string buf (Printf.sprintf
    {|<li><a href="%sindex.html#routes">Routes</a></li>|} prefix);
  Buffer.add_string buf (Printf.sprintf
    {|<li><a href="%sindex.html#liveviews">LiveViews</a></li>|} prefix);
  Buffer.add_string buf (Printf.sprintf
    {|<li><a href="%sindex.html#modules">Modules</a></li>|} prefix);
  Buffer.add_string buf {|</ul>|};
  Buffer.add_string buf {|<div class="section-label">Modules</div><ul>|};
  List.iter (fun (m : Doc_parser.module_doc) ->
    Buffer.add_string buf (Printf.sprintf
      {|<li><a href="%smodules/%s.html">%s</a></li>|}
      prefix m.name (escape_html m.name))
  ) modules;
  Buffer.add_string buf {|</ul>|};
  Buffer.contents buf

(* Generate index.html *)
let generate_index ~project_name ~modules =
  let routes = collect_routes modules in
  let liveviews = collect_liveviews modules in
  let buf = Buffer.create 4096 in

  (* Header *)
  Buffer.add_string buf (Printf.sprintf
    {|<h1>%s</h1><p class="subtitle">Documentation generated by <code>well docs</code></p>|}
    (escape_html project_name));

  (* Routes *)
  Buffer.add_string buf {|<h2 id="routes">Routes</h2>|};
  if routes = [] then
    Buffer.add_string buf {|<p class="empty">No routes registered.</p>|}
  else begin
    Buffer.add_string buf
      {|<table><thead><tr><th>Method</th><th>Path</th><th>Module</th><th>Description</th></tr></thead><tbody>|};
    List.iter (fun (meth, path, mod_name, doc, _line) ->
      let short_doc = match String.index_opt doc '\n' with
        | Some i -> String.sub doc 0 i
        | None -> doc
      in
      Buffer.add_string buf (Printf.sprintf
        {|<tr><td>%s</td><td><code>%s</code></td><td><a href="modules/%s.html">%s</a></td><td>%s</td></tr>|}
        (method_tag meth) (escape_html path) mod_name (escape_html mod_name)
        (escape_html short_doc))
    ) routes;
    Buffer.add_string buf {|</tbody></table>|}
  end;

  (* LiveViews *)
  Buffer.add_string buf {|<h2 id="liveviews">LiveViews</h2>|};
  if liveviews = [] then
    Buffer.add_string buf {|<p class="empty">No LiveViews registered.</p>|}
  else begin
    Buffer.add_string buf
      {|<table><thead><tr><th>Path</th><th>Module</th><th>Description</th></tr></thead><tbody>|};
    List.iter (fun (path, mod_name, doc) ->
      let short_doc = match String.index_opt doc '\n' with
        | Some i -> String.sub doc 0 i
        | None -> doc
      in
      Buffer.add_string buf (Printf.sprintf
        {|<tr><td><span class="tag tag-live">LIVE</span> <code>%s</code></td><td><a href="modules/%s.html">%s</a></td><td>%s</td></tr>|}
        (escape_html path) mod_name (escape_html mod_name)
        (escape_html short_doc))
    ) liveviews;
    Buffer.add_string buf {|</tbody></table>|}
  end;

  (* Modules *)
  Buffer.add_string buf {|<h2 id="modules">Modules</h2>|};
  Buffer.add_string buf {|<div class="module-list">|};
  List.iter (fun (m : Doc_parser.module_doc) ->
    let short_doc =
      if m.doc <> "" then
        let first = match String.index_opt m.doc '\n' with
          | Some i -> String.sub m.doc 0 i
          | None -> m.doc
        in
        Printf.sprintf {|<div style="font-size:0.8125rem;color:var(--text-muted);margin-top:0.25rem">%s</div>|}
          (escape_html first)
      else ""
    in
    Buffer.add_string buf (Printf.sprintf
      {|<a href="modules/%s.html" class="module-card" style="text-decoration:none;color:inherit"><div class="name">%s</div><div class="path">%s</div>%s</a>|}
      m.name (escape_html m.name) (escape_html m.path) short_doc)
  ) modules;
  Buffer.add_string buf {|</div>|};

  let sb = sidebar_html ~project_name ~modules ~is_subpage:false in
  page_wrapper ~title:(project_name ^ " — Documentation") ~sidebar_html:sb
    ~content_html:(Buffer.contents buf)

(* Generate module page *)
let generate_module_page ~project_name ~modules (m : Doc_parser.module_doc) =
  let buf = Buffer.create 4096 in

  Buffer.add_string buf (Printf.sprintf
    {|<h1>%s</h1><p class="subtitle"><code>%s</code></p>|}
    (escape_html m.name) (escape_html m.path));

  if m.doc <> "" then
    Buffer.add_string buf (Printf.sprintf
      {|<div class="item-doc">%s</div>|} (doc_to_html m.doc));

  (* Separate items by kind *)
  let types = List.filter (fun (i : Doc_parser.doc_item) -> i.kind = Type) m.items in
  let functions = List.filter (fun (i : Doc_parser.doc_item) ->
    i.kind = Function || i.kind = Value) m.items in
  let routes = List.filter (fun (i : Doc_parser.doc_item) ->
    match i.kind with Route _ -> true | _ -> false) m.items in
  let liveviews = List.filter (fun (i : Doc_parser.doc_item) ->
    match i.kind with LiveView _ -> true | _ -> false) m.items in
  let submodules = List.filter (fun (i : Doc_parser.doc_item) -> i.kind = Module) m.items in

  (* Routes section *)
  if routes <> [] then begin
    Buffer.add_string buf {|<h2>Routes</h2>|};
    List.iter (fun (item : Doc_parser.doc_item) ->
      let tag_html = match item.kind with
        | Route (meth, path) ->
          Printf.sprintf {|%s <code>%s</code>|}
            (method_tag meth) (escape_html path)
        | _ -> ""
      in
      Buffer.add_string buf (Printf.sprintf
        {|<div class="item"><div class="item-name">%s</div>|} tag_html);
      if item.doc <> "" then
        Buffer.add_string buf (Printf.sprintf
          {|<div class="item-doc">%s</div>|} (doc_to_html item.doc));
      Buffer.add_string buf {|</div>|}
    ) routes
  end;

  (* LiveViews section *)
  if liveviews <> [] then begin
    Buffer.add_string buf {|<h2>LiveViews</h2>|};
    List.iter (fun (item : Doc_parser.doc_item) ->
      Buffer.add_string buf (Printf.sprintf
        {|<div class="item"><div class="item-name"><span class="tag tag-live">LIVE</span> <code>%s</code></div>|}
        (escape_html item.name));
      if item.doc <> "" then
        Buffer.add_string buf (Printf.sprintf
          {|<div class="item-doc">%s</div>|} (doc_to_html item.doc));
      Buffer.add_string buf {|</div>|}
    ) liveviews
  end;

  (* Types section *)
  if types <> [] then begin
    Buffer.add_string buf {|<h2>Types</h2>|};
    List.iter (fun (item : Doc_parser.doc_item) ->
      Buffer.add_string buf (Printf.sprintf
        {|<div class="item"><div class="item-name">%s</div>|}
        (escape_html item.name));
      if item.signature <> "" then
        Buffer.add_string buf (Printf.sprintf
          {|<div class="item-sig">%s</div>|} (escape_html item.signature));
      if item.doc <> "" then
        Buffer.add_string buf (Printf.sprintf
          {|<div class="item-doc">%s</div>|} (doc_to_html item.doc));
      Buffer.add_string buf {|</div>|}
    ) types
  end;

  (* Functions section *)
  if functions <> [] then begin
    Buffer.add_string buf {|<h2>Functions</h2>|};
    List.iter (fun (item : Doc_parser.doc_item) ->
      Buffer.add_string buf (Printf.sprintf
        {|<div class="item"><div class="item-name">%s</div>|}
        (escape_html item.name));
      if item.signature <> "" then
        Buffer.add_string buf (Printf.sprintf
          {|<div class="item-sig">%s</div>|} (escape_html item.signature));
      if item.doc <> "" then
        Buffer.add_string buf (Printf.sprintf
          {|<div class="item-doc">%s</div>|} (doc_to_html item.doc));
      Buffer.add_string buf {|</div>|}
    ) functions
  end;

  (* Submodules section *)
  if submodules <> [] then begin
    Buffer.add_string buf {|<h2>Modules</h2>|};
    List.iter (fun (item : Doc_parser.doc_item) ->
      Buffer.add_string buf (Printf.sprintf
        {|<div class="item"><div class="item-name">%s</div>|}
        (escape_html item.name));
      if item.doc <> "" then
        Buffer.add_string buf (Printf.sprintf
          {|<div class="item-doc">%s</div>|} (doc_to_html item.doc));
      Buffer.add_string buf {|</div>|}
    ) submodules
  end;

  let sb = sidebar_html ~project_name ~modules ~is_subpage:true in
  page_wrapper ~title:(m.name ^ " — " ^ project_name)
    ~sidebar_html:sb ~content_html:(Buffer.contents buf)

(* Write file, creating parent dirs *)
let write_file path content =
  let dir = Filename.dirname path in
  let rec mkdir_p d =
    if d <> "" && d <> "." && d <> "/" && not (Sys.file_exists d) then begin
      mkdir_p (Filename.dirname d);
      Sys.mkdir d 0o755
    end
  in
  mkdir_p dir;
  let oc = open_out path in
  output_string oc content;
  close_out oc

(* Main entry point *)
let generate ~project_name ~output_dir ~modules =
  (* Sort modules alphabetically *)
  let modules = List.sort (fun (a : Doc_parser.module_doc) (b : Doc_parser.module_doc) ->
    String.compare a.name b.name) modules in

  (* Write CSS *)
  write_file (Filename.concat output_dir "style.css") css;

  (* Write index *)
  let index_html = generate_index ~project_name ~modules in
  write_file (Filename.concat output_dir "index.html") index_html;

  (* Write module pages *)
  List.iter (fun m ->
    let html = generate_module_page ~project_name ~modules m in
    let path = Filename.concat output_dir (Printf.sprintf "modules/%s.html" m.Doc_parser.name) in
    write_file path html
  ) modules;

  List.length modules
