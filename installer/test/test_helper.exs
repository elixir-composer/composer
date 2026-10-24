# The integration test builds and installs the archive and generates a real
# app; run it with `mix test --only integration`.
ExUnit.start(exclude: [:integration])
