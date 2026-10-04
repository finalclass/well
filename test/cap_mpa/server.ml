let () =
  Well.Db.register_table
    { name= "cap_items"
    ; columns=
        [ {cname= "id"; sqlite_type= "INTEGER"; primary= true; nullable= false}
        ; {cname= "name"; sqlite_type= "TEXT"; primary= false; nullable= false}
        ] } ;
  let db = Well.Db.open_db () in
  for id = 1 to 25 do
    ignore
      (Sqlite3.exec
         db
         (Printf.sprintf
            "INSERT OR IGNORE INTO cap_items(id,name) VALUES(%d,'Pozycja %d')"
            id
            id ) )
  done ;
  ignore (Sqlite3.db_close db) ;
  let spec =
    { Well.Service.dname= "CapDemo"
    ; drpcs=
        [ { Well.Service.rname= "echoInt"
          ; params=
              [{Well.Service.pname= "value"; ptype= "int"; poptional= false}]
          ; returns=
              [{Well.Service.pname= "value"; ptype= "int"; poptional= false}]
          ; returns_name= "IntEcho" } ]
    ; dhandler= (fun _ _ payload -> Ok payload)
    ; dset_ref= ignore }
  in
  Well.Service.register_drut spec ;
  Well.get "/acceptance-event" (fun _ ->
      ignore
        (Well.MessageBus.publish
           ~ephemeral:true
           "cap-acceptance"
           (`String "Wiadomość testowa") ) ;
      Well.Log.log "Log testowy CAP" ;
      Well.text "ok" ) ;
  Well.use Well.csrf ;
  Well.run
    ~host:"127.0.0.1"
    ~port:
      (Option.value
         (Option.bind (Sys.getenv_opt "CAP_PORT") int_of_string_opt)
         ~default:8493 )
    ()
