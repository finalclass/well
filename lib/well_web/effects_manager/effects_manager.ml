[@@@warning "-27-69"]

type 'a envelope = {
  instance_id : string;
  payload : 'a;
}

let handle_cmd ~instance_id envelope = ()
