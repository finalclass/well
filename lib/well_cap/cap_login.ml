let login_page ?(error = false) () =
  let error_html =
    if error then
      {|<div class="login-error">Invalid password</div>|}
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
    <p class="sub">Enter the cap password to continue</p>
    %s
    <form method="post" action="/_well/login">
      <label for="password">Password</label>
      <input type="password" id="password" name="password"
             class="input" placeholder="WELL_CAP_PASS" autofocus />
      <button type="submit" class="btn btn-accent">Sign in</button>
    </form>
  </div>
</div>
</body>
</html>|}
    Cap_css.css error_html
