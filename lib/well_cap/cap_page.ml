let cap_page req ~path ~title ~content =
  Cap_layout.cap_layout req ~active_path:path ~title ~content
