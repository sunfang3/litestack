# Run:
#   rails new my-app -m https://raw.githubusercontent.com/oldmoe/litestack/master/template.rb
# Requires Ruby >= 4.0 and Rails >= 8.1, < 9.
gem "litestack", "~> 1.0"

after_bundle do
  generate "litestack:install"
end
