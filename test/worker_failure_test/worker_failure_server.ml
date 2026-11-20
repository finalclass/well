let write path text =
  let channel = open_out_bin path in
  output_string channel text;
  close_out channel

let self_signed () =
  let key = X509.Private_key.generate `P256 in
  let name =
    [ X509.Distinguished_name.(
        Relative_distinguished_name.singleton (CN (Common_name.v "localhost"))) ]
  in
  let request =
    match X509.Signing_request.create name key with
    | Ok request -> request
    | Error _ -> failwith "signing request"
  in
  let valid_until = Option.get (Ptime.of_date (2100, 1, 1)) in
  match
    X509.Signing_request.sign request ~valid_from:Ptime.epoch ~valid_until key
      name
  with
  | Ok certificate -> (certificate, key)
  | Error _ -> failwith "certificate"

let () =
  Mirage_crypto_rng_unix.use_default ();
  let port = int_of_string Sys.argv.(1) in
  let certificate, key = self_signed () in
  let cert = Filename.concat (Sys.getcwd ()) "cert.pem" in
  let key_path = Filename.concat (Sys.getcwd ()) "key.pem" in
  write cert (X509.Certificate.encode_pem certificate);
  write key_path (X509.Private_key.encode_pem key);
  Well.max_connections_per_ip 1;
  Well.get "/ready" (fun _ -> `Text "ready");
  Well.run ~port ~workers:2 ~cert ~key:key_path ()
