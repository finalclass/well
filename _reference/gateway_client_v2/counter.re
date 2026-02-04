open Base;

[@deriving yojson]
type model = {
  count: int,
  step: int,
};

[@deriving yojson]
type msg =
  | Increment
  | Decrement
  | Reset
  | SetStep(int);

let persistence = Liveview.User;

let init = (_ctx: Liveview.ctx, props: Yojson.Safe.t): model => {
  open Yojson.Safe.Util;
  let get_int = (key, default) =>
    try(props |> member(key) |> to_int) {
    | _ =>
      try(props |> member(key) |> to_string |> Int.of_string) {
      | _ => default
      }
    };
  {
    count: get_int("initial", 0),
    step: get_int("step", 1),
  };
};

let update = (_ctx: Liveview.ctx, model: model, msg: msg): model =>
  switch (msg) {
  | Increment => {
      ...model,
      count: model.count + model.step,
    }
  | Decrement => {
      ...model,
      count: model.count - model.step,
    }
  | Reset => {
      ...model,
      count: 0,
    }
  | SetStep(step) => {
      ...model,
      step,
    }
  };

let render = (model: model): Html.element => {
  Html.(
    <div className="counter">
      <div className="counter-display">
        {dynamic("count", Int.to_string(model.count))}
      </div>
      <div className="counter-controls">
        <lvButton click="Decrement" className="counter-btn">
          {txt("-")}
        </lvButton>
        <lvButton click="Increment" className="counter-btn">
          {txt("+")}
        </lvButton>
        <lvButton click="Reset" className="counter-btn secondary">
          {txt("Reset")}
        </lvButton>
      </div>
      <div className="counter-step">
        {txt("Step: ")}
        {dynamic("step", Int.to_string(model.step))}
      </div>
    </div>
  );
};
