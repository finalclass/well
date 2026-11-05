type 'a topic = 'a Well.topic
type 'a event = 'a Well.event = { id : int; value : 'a; created_at : float }
type 'a keyed_event = 'a Well.keyed_event = { key : string; event : 'a event }

let topic = Well.topic
let topic_name = Well.topic_name
