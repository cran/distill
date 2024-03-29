

#' R Markdown site generator for Distill websites
#'
#' @inheritParams rmarkdown::default_site_generator
#'
#' @export
distill_website <- function(input, encoding = getOption("encoding"), ...) {

  # create an output format filter that allows for alternate output formats
  config <- site_config(input, encoding)
  output_format_filter <- NULL
  if (!identical(config$alt_formats, FALSE)) {
    output_format_filter <- function(input_file, output_format) {
      alt_format <- alt_output_format(input_file, config)
      if (!is.null(alt_format)) {
        alt_format
      } else {
        output_format
      }
    }
  }

  # create the default site generator
  default <- rmarkdown::default_site_generator(input, output_format_filter, ...)

  # then wrap/delegate to the render and clean functions
  list(
    name = default$name,

    output_dir = default$output_dir,

    render = function(input_file, output_format, envir, quiet, encoding, ...) {

      # get the site config and collections
      config <- site_config(input, encoding)
      site_collections <- site_collections(input, config)

      # check if this is an incremental render
      incremental <- !is.null(input_file)

      # if it's not an incremental render then scan top level Rmds for listings
      # to add to site_collections
      if (!incremental) {
        input_files <- list.files(input, pattern = "^[^_].*\\.[Rr]?md$", full.names = TRUE)
        sapply(input_files, function(file) {
          listings <- front_matter_listings (file, encoding)
          for (listing in listings) {
            if (is.null(site_collections[[listing]])) {
              site_collections[[listing]] <<- list(name = listing)
            }
          }
        })

      # if it's incremental then only render collection(s) specified in listing:
      } else {
        metadata <- yaml_front_matter(input_file, encoding)
        listings <- front_matter_listings(input_file, encoding)
        if (length(listings) > 0) {
          site_collections <- lapply(listings, function(listing) {
            if (!is.null(site_collections[[listing]]))
              site_collections[[listing]]
            else
              list(name = listing)
          })
          names(site_collections) <- listings
        }
      }

      # enumerate collections
      collections <- enumerate_collections(input, config, site_collections)

      # write metadata (do this now so that pages have access to collection metadata)
      write_collections_metadata(input, collections)
      on.exit(remove_collections_metadata(input, collections), add = TRUE)

      # track site outputs (for moving to the output_dir)
      track_site_outputs(config$output_dir)
      on.exit(remove_site_outputs(), add = TRUE)

      # delegate to default site generator
      result <- default$render(input_file, output_format, envir, quiet, encoding, ...)

      # render collections to the output directory
      render_collections(input, config, collections, quiet)

      # write sitemap
      write_sitemap_xml(input, config)

      # write top level article search index
      # if search is activated
      if (site_search_enabled(config)) {
        write_search_json(input, config)
      }

      # return result
      result
    },

    clean = function() {

      # files generated by default site generator
      generated <- default$clean()

      # if we are generating in-place then add collection metadata and dirs
      config <- site_config(input, encoding)
      if (config$output_dir == ".") {
        # collection output directories
        collections <- site_collections(input, config)
        for (collection in names(collections)) {
          generated <- c(generated,
            file.path(paste0("_", collection), paste0(collection, ".yml")),
            paste0(collection, "/")
          )
        }
        # sitemap
        generated <- c(generated, "sitemap.xml")
      }

      # filter out by existence
      generated[file.exists(file.path(input, generated))]
    }
  )
}


.site_outputs <- new.env(parent = emptyenv())
.site_outputs$files <- c()
.site_outputs$output_dir <- NULL

track_site_outputs <- function(output_dir) {
  .site_outputs$files <- c()
  .site_outputs$output_dir <- output_dir
}

add_site_output <- function(file) {
  .site_outputs$files <- c(.site_outputs$files, file)
  file
}

remove_site_outputs <- function() {

  on.exit({
    .site_outputs$files <- c()
    .site_outputs$output_dir <- NULL
  }, add = TRUE)

  if (.site_outputs$output_dir != ".")
    lapply(.site_outputs$files, file.remove)
}

# if the input file uses an alternate output format then inject
# requisite distill site header/footer/etc.
alt_output_format <- function(input_file, config) {

  # check for a non distil format
  alt_format <- non_distill_format(input_file)
  if (!is.null(alt_format)) {

    # ensure site deps are copied to the site_libs dir
    ensure_site_dependencies(config, dirname(input_file))

    # create format
    output_format <- rmarkdown::resolve_output_format(
      input = input_file,
      output_format = alt_format
    )

    # ensure we have required title config
    config <- transform_site_config(config)

    # header includes (provide theme if we have one)
    in_header <- c(
      navigation_in_header_file(config),
      site_in_header_file(config),
      alt_format_in_header_file()
    )
    theme <- theme_from_site_config(find_site_dir(input_file), config)
    if (!is.null(theme)) {
      in_header <- c(in_header, theme_in_header_file(theme))
    }

    # inject distill sauce
    args <- c(
      output_format$pandoc$args,
      pandoc_include_args(
        in_header = in_header,
        before_body = c(
          navigation_before_body_file(dirname(input_file), config),
          site_before_body_file(config)
        ),
        after_body = c(
          site_after_body_file(config),
          navigation_after_body_file(dirname(input_file), config)
        )
      )
    )

    # prevent self-contained
    args <- args[args != "--self-contained"]

    # set args and return format
    output_format$pandoc$args <- args
    output_format
  } else {
    NULL
  }
}

non_distill_format <- function(input_file) {
  formats <- rmarkdown::all_output_formats(input_file)
  formats <- formats[formats != "distill::distill_article"]
  if (length(formats) > 0)
    formats[[1]]
  else
    NULL
}

alt_format_in_header_file <- function() {
  system.file("rmarkdown/templates/distill_article/resources/alt-format.html",
              package = "distill")
}




