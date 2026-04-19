# Displays the list of available commands
@just:
    just --list

# Serves the site locally with live reload at http://localhost:3000
serve:
    bamboo serve --open

# Builds the site to dist/
build:
    bamboo build

# Builds the site for the matthewberger.dev/articles deployment
build-release:
    bamboo build --base-url "https://matthewberger.dev/articles"

# Removes the build output and incremental cache
clean:
    rm -rf dist .bamboo-cache
