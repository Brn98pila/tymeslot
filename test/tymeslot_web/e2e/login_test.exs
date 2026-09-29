defmodule TymeslotWeb.E2E.LoginTest do
  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :auth

  feature "user can log in with valid credentials", %{session: session} do
    user = create_onboarded_user()

    session
    |> visit("/auth/login")
    |> wait_for_live()
    |> fill_in(text_field("email"), with: user.email)
    |> fill_in(css("#password-input"), with: default_password())
    |> click(css("button[type='submit']"))
    |> wait_for_dashboard()
  end

  feature "login with invalid credentials shows error", %{session: session} do
    user = create_onboarded_user()

    session
    |> visit("/auth/login")
    |> wait_for_live()
    |> fill_in(text_field("email"), with: user.email)
    |> fill_in(css("#password-input"), with: "WrongPassword99!")
    |> click(css("button[type='submit']"))
    |> assert_has(css(".bg-red-50"))
  end

  # The login form keeps the browser's own validation: an empty submit is
  # stopped before it costs a full-page round trip.
  feature "an empty login is stopped by the browser", %{session: session} do
    session =
      session
      |> visit("/auth/login")
      |> wait_for_live()
      |> click(css("button[type='submit']"))

    assert current_path(session) == "/auth/login"

    execute_script(
      session,
      "return document.querySelector('#login-form input[name=email]').matches(':invalid')",
      fn invalid? -> assert invalid? end
    )
  end

  feature "login page fits the narrowest supported viewport", %{session: session} do
    session
    |> resize_to_mobile()
    |> visit("/auth/login")
    |> wait_for_live()
    |> assert_has(css("#password-input"))
    |> assert_no_horizontal_overflow("login page at 320px")
  end
end
