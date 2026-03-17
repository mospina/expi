ExUnit.start()

# Test coverage configuration
if System.get_env("COVERAGE") do
  ExUnit.configure(exclude: [:skip])
else
  ExUnit.configure(exclude: [:skip, :integration])
end
