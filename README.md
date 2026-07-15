# cloudindexer for LanguageServer.jl

[![Regenerate symbol cache](https://github.com/julia-vscode/cloudindexer/actions/workflows/regen-symbolcache.yml/badge.svg)](https://github.com/julia-vscode/cloudindexer/actions/workflows/regen-symbolcache.yml)

Daily runs of the JuliaWorkspaces.jl based registry indexer. It creates cache files for every new
package version registered into General and pushes them into an R2 bucket for general availability.
