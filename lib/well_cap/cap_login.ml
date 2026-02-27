let login_page ?(error = "") () =
  let error_html =
    if error <> "" then
      Printf.sprintf {|<div class="login-error">%s</div>|} (Html.escape_html error)
    else ""
  in
  Printf.sprintf
    {|<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Login — well.cap</title>
<style>%s</style>
</head>
<body>
<div class="login-wrap">
  <div class="login-card">
    <h1>well.cap</h1>
    <p class="sub">Sign in to continue</p>
    %s
    <form method="post" action="/_cap/login">
      <label for="email">Login</label>
      <input type="text" id="email" name="email"
             class="input" placeholder="Email or username" autofocus />
      <label for="password">Password</label>
      <input type="password" id="password" name="password"
             class="input" placeholder="Password" />
      <button type="submit" class="btn btn-accent">Sign in</button>
    </form>
  </div>
</div>
</body>
</html>|}
    Cap_css.css error_html
