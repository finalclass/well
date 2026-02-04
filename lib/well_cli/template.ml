let dune_project name =
  Printf.sprintf
    {|(lang dune 3.17)

(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (preprocess
   (run mlx-pp %%{input-file}))))

(pin
 (url "file:///home/sel/Documents/well")
 (package (name well)))

(package
 (name %s)
 (allow_empty)
 (synopsis "A well web application")
 (depends
  (ocaml (>= 5.2))
  mlx
  well
  eio
  eio_main
  yojson))
|}
    name

let root_dune = {|(dirs :standard \ _build)
|}

let makefile =
  {|.PHONY: build check test clean lock dev

build:
	dune build

check:
	dune build @check

test:
	dune test

clean:
	dune clean

lock:
	dune pkg lock

dev:
	dune exec bin/main.exe
|}

let gitignore =
  {|_build/
*.install
.merlin
_opam/
_esy/
|}

let bin_dune name =
  Printf.sprintf
    {|(executable
 (name main)
 (libraries %s_web well.core eio_main))
|}
    name

let bin_main name =
  let mod_name = String.capitalize_ascii name in
  String.concat ""
    [
      "let () =\n";
      "  Well_core.run @@ fun _env ->\n";
      Printf.sprintf
        "  Printf.printf \"[well] %%s v%%s started\\n\" %s.name %s.version\n"
        mod_name mod_name;
    ]

let lib_dune name =
  Printf.sprintf
    {|(library
 (name %s)
 (libraries well.core eio yojson))
|}
    name

let lib_main name =
  Printf.sprintf {|let name = "%s"
let version = "0.1.0"
|}
    name

let lib_web_dune name =
  Printf.sprintf
    {|(library
 (name %s_web)
 (libraries %s well.core well.html eio yojson))
|}
    name name

let router _name =
  {|let routes = [
  ("/", "home");
]
|}

let home_page name =
  Printf.sprintf
    {|open Html

let render () =
  <div>
    <h1>"Welcome to %s"</h1>
    <p>"Edit lib/%s_web/home_page.mlx to get started."</p>
  </div>
|}
    name name

let layout name =
  Printf.sprintf
    {|open Html

let render ~title:page_title ~children =
  <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name_="viewport" content="width=device-width, initial-scale=1.0" />
      <title>page_title</title>
    </head>
    <body>
      <main>children</main>
      <footer>
        <p>"Powered by %s & well"</p>
      </footer>
    </body>
  </html>
|}
    name

let test_dune name =
  Printf.sprintf
    {|(test
 (name %s_test)
 (libraries %s))
|}
    name name

let test_main name =
  Printf.sprintf
    {|let () =
  Printf.printf "%s tests\n";
  assert (String.length %s.name > 0);
  Printf.printf "All tests passed!\n"
|}
    name (String.capitalize_ascii name)

let static_gitkeep = ""

type file = {
  path : string;
  content : string;
}

let project_files name =
  [
    { path = "dune-project"; content = dune_project name };
    { path = "dune"; content = root_dune };
    { path = "Makefile"; content = makefile };
    { path = ".gitignore"; content = gitignore };
    { path = "bin/dune"; content = bin_dune name };
    { path = "bin/main.ml"; content = bin_main name };
    { path = Printf.sprintf "lib/%s/dune" name; content = lib_dune name };
    { path = Printf.sprintf "lib/%s/%s.ml" name name; content = lib_main name };
    { path = Printf.sprintf "lib/%s_web/dune" name; content = lib_web_dune name };
    { path = Printf.sprintf "lib/%s_web/router.ml" name; content = router name };
    {
      path = Printf.sprintf "lib/%s_web/home_page.mlx" name;
      content = home_page name;
    };
    {
      path = Printf.sprintf "lib/%s_web/layout.mlx" name;
      content = layout name;
    };
    { path = "test/dune"; content = test_dune name };
    {
      path = Printf.sprintf "test/%s_test.ml" name;
      content = test_main name;
    };
    { path = "static/.gitkeep"; content = static_gitkeep };
  ]
