## These are helper functions to run hliang's cnv-seq tool found in:
## - https://github.com/hliang/cnv-seq
##
## Most of the functions below are from the 'Bioconductor Helper Functions'
## in Bioconductor's copy-number-analysis repository
## 
## - https://github.com/Bioconductor/copy-number-analysis
##
## We had to patch the function ("as.countsfile") and added additional 'PBGL Helper Functions'.


#################################################################################
######################### Bioconductor Helper Functions #########################
#################################################################################

## samtools view -F 4 tumorA.chr4.bam |\
##     perl -lane 'print "$F[2]\t$F[3]"' >tumor.hits
## samtools view -F 4 normalA.chr4.bam |\
##     perl -lane 'print "$F[2]\t$F[3]"' >normal.hits
## perl cnv-seq/cnv-seq.pl --test tumor.hits --ref normal.hits \
##     --genome human --Rexe "~/bin/R-devel/bin/R"

# extract genome size from bam file
genomeSize <- function(files)
    sum(as.numeric(seqlengths(BamFile(files[[1]]))))

# calculate window size with default parameters if parameters
# not provided in config file
windowSize <-
    function(bam_files, pvalue=0.001, log2=0.6, bigger=1.5,
             genome_size, param)
{
    if (missing(genome_size))
        genome_size=genomeSize(bam_files)
    if (missing(param))
        param <- ScanBamParam(flag=scanBamFlag(isUnmappedQuery=FALSE))

    total <- sapply(bam_files, function(...) {
        countBam(...)$records
    }, param=param)

    bt <- qnorm(1 - pvalue / 2)
    st <- qnorm(pvalue / 2)
    log2 <- abs(log2)
    brp <- 2^log2
    srp <- 1 / (2^log2)
    
    bw <- (total[["test"]] * brp^2 + total[["ref"]]) * genome_size * bt^2 /
        ((1-brp)^2 * total[["test"]] * total[["ref"]])
    sw <- (total[["test"]] * srp^2 + total[["ref"]]) * genome_size * st^2 /
        ((1-srp)^2 * total[["test"]] * total[["ref"]])

    window_size = floor(max(bw, sw) * bigger)
}

# find genome overlaps per tile
tileGenomeOverlap <- function(file, tilewidth) {
    ## overlapping tiles
    lengths <- seqlengths(BamFile(file[[1]]))
    tile0 <- tileGenome(lengths, tilewidth=tilewidth,
                        cut.last.tile.in.chrom=TRUE)
    tile1 <- tile0[width(tile0) >= tilewidth]
    tile1 <- shift(tile1[-cumsum(runLength(seqnames(tile1)))], tilewidth / 2)
    sort(c(tile0, tile1))
}

# count overlaps
binCounter <- function(features, reads, ignore.strand, ...) {
    countOverlaps(features, resize(granges(reads), 1),
                  ignore.strand=ignore.strand) 
}

# convert S4 object to tab file
# as.countsfile <- function(hits, file=tempfile()) {
#     df <- with(rowData(hits), {
#         cbind(data.frame(chromosome=as.character(seqnames),
#                          start=start, end=end),
#               assay(hits))
#     })
#     write.table(df, file, quote=FALSE, row.names=FALSE, sep="\t")
#     file
# }

#################################################################################
############################# PBGL Helper Functions #############################
#################################################################################

# modified as.countsfile() function to convert S4 object to tab file
as.countsfile <- function(hits, fileNameAndLocation) {
    df <- with(rowData(hits), {
        chrome = hits@rowRanges@seqnames
        start = hits@rowRanges@ranges
        end = hits@rowRanges@ranges@start + hits@rowRanges@ranges@width - 1
        cbind(data.frame(chromosome=chrome,
                         start=start,
                         end=end),
                         assay(hits))
    })

    df = subset(df, select = -c(end))
    names(df)[names(df) == "start.start"] <- "start"
    names(df)[names(df) == "start.end"] <- "end"
    names(df)[names(df) == "start.width"] <- "width"

    write.table(df, file = fileNameAndLocation, quote=FALSE, row.names=FALSE, sep="\t")
    return(fileNameAndLocation)
}

# convert bed dataframe to GRanges object
toGRanges <- function(bed_dataframe){
    GRanges(seqnames = bed_dataframe$V1, 
            ranges = IRanges(start = bed_dataframe$V2,
                             end = bed_dataframe$V3))
}

# calculate copy number ratios from provided config file
cnvCalculate <- function(config){
    # create output directory to store images/tab-files
    output_path <- config$output_path
    dir.create(output_path)
    
    output_path_tab <- paste(output_path, "/tab-files", sep="")
    dir.create(output_path_tab)
    
    output_path_img <- paste(output_path, "/images", sep="")
    dir.create(output_path_img)
    
    # store comparisons to be done
    comparisons <- config$comparisons
    comparisonNames <- names(config$comparisons)

    # store chromosomes to subset
    chromosomes <- unlist(strsplit(gsub(" ", "", config$chromosomes), ","))

    # store provided parameters
    parameters <- config$parameters
    parameterNames <- names(config$parameters)

    # first check if parameter exists. if exist, store value,
    # if not exist, use default values
    if ('annotate' %in% parameterNames){
        annotate <- config$parameters$annotate
    } else {annotate <- TRUE}
    if ('bed_file_present' %in% parameterNames){
        bed_file <- config$parameters$bed_file_present
    } else {bed_file <- FALSE}
    if ('bigger' %in% parameterNames){
        bigger <- config$parameters$bigger
    } else {bigger <- 1.5}
    if ('log2' %in% parameterNames){
        log2 <- config$parameters$log2
    } else {log2 <- 0.6}
    if ('pvalue' %in% parameterNames){
        pvalue <- config$parameters$pvalue
    } else {pvalue <- 0.001}
    if ('window_size' %in% parameterNames){
        window_size <- config$parameters$window_size
    } else {window_size <- 10000}
    
    for (comparison in comparisonNames){
        cat(paste("\nComparison:", comparison))
        cat(paste("\nComparing samples:\n"))

        # files to compare
        control <- config$comparisons[[comparison]]$control
        mutant <- config$comparisons[[comparison]]$mutant

        cat(paste(control, "\nvs.\n", mutant, "\n\n"))

        # name mutant as "test" and control as "ref"
        files <- file.path(c(mutant, control))
        names(files) <- c("test", "ref")

        # calculate overall captures/tiles and hits
        if ('bed_file_present' %in% parameterNames) { # if 'bed_file' object present in config
            # extract TRUE or FALSE value
            bed_file <- config$parameters$bed_file_present

            if (isTRUE(bed_file)) { # bed_file == TRUE
                # extract path to BED file
                bedPath <- config$bed_path

                # convert BED to dataframe df
                BEDdf <- read.table(bedPath, header=FALSE, sep="\t", stringsAsFactors=FALSE, quote="")

                # split and convert per region
                captures <- toGRanges(BEDdf)
                hits <- summarizeOverlaps(captures, files, binCounter)

            } else { # bed_file == FALSE, 
                bed_file <- FALSE

                # extract window_size or calculate if missing
                if ('window_size' %in% parameterNames){
                    window_size <- config$parameters$window_size
                } else {
                    window_size <- windowSize(files, pvalue=pvalue, log2=log2, bigger=bigger)
                }

                tiles <- tileGenomeOverlap(files, window_size)
                hits <- summarizeOverlaps(tiles, files, binCounter)
            }
        } else { # 'bed_file' object not present in config
            bed_file <- FALSE

            # extract window_size or calculate if missing
            if ('window_size' %in% parameterNames){
                window_size <- config$parameters$window_size
            } else {
                window_size <- windowSize(files, pvalue=pvalue, log2=log2, bigger=bigger)
            }

            tiles <- tileGenomeOverlap(files, window_size)
            hits <- summarizeOverlaps(tiles, files, binCounter)
        }

        # subset only those chromosomes defined in config file
        hitsChrSubset <- subset(hits, seqnames %in% chromosomes)

        # create tabulated file with dataframe
        if (bed_file) {
            hitsPath <- paste(output_path, "tab-files/", comparison, "-all-hits-captures-BED.tab", sep="")
            hitsFile <- as.countsfile(hitsChrSubset, hitsPath)
        } else {
            hitsPath <- paste(output_path, "tab-files/", comparison, "-window-", window_size, "-all-hits.tab", sep="")
            hitsFile <- as.countsfile(hitsChrSubset, hitsPath)
        }


        # calculate Copy Number Variations (CNVs)
        cnv <- cnv.cal(hitsFile, log2=log2, annotate=annotate)

        # print summary of CNVs per chromosome
        cat("\n")
        cnv.summary(cnv)

        # save all considered CNVs calculated by cnv.cal( ) function and print
        cnvFile <- paste(output_path, "tab-files/", comparison, "-all-chroms-CNVs.tab", sep="")
        cnv.print(cnv, file=cnvFile)
        cat("\n")
        cnv.print(cnv)
    }
}

# plot copy number ratios for whole genome and per chromosome
cnvPlot <- function(config, imgType="png", yMin=-5, yMax=5){
    # create output directory to store images/tab-files
    output_path <- config$output_path
    dir.create(output_path)
    
    output_path_tab <- paste(output_path, "/tab-files", sep="")
    dir.create(output_path_tab)
    
    output_path_img <- paste(output_path, "/images", sep="")
    dir.create(output_path_img)
    
    # store comparisons to be done
    comparisons <- config$comparisons
    comparisonNames <- names(config$comparisons)

    # store chromosomes to subset
    chromosomes <- unlist(strsplit(gsub(" ", "", config$chromosomes), ","))

    # store provided parameters
    parameters <- config$parameters
    parameterNames <- names(config$parameters)

    # first check if parameter exists. if exist, store value,
    # if not exist, use default values
    if ('annotate' %in% parameterNames){
        annotate <- config$parameters$annotate
    } else {annotate <- TRUE}
    if ('bed_file_present' %in% parameterNames){
        bed_file <- config$parameters$bed_file_present
    } else {bed_file <- FALSE}
    if ('bigger' %in% parameterNames){
        bigger <- config$parameters$bigger
    } else {bigger <- 1.5}
    if ('log2' %in% parameterNames){
        log2 <- config$parameters$log2
    } else {log2 <- 0.6}
    if ('pvalue' %in% parameterNames){
        pvalue <- config$parameters$pvalue
    } else {pvalue <- 0.001}
    if ('window_size' %in% parameterNames){
        window_size <- config$parameters$window_size
    } else {window_size <- 10000}
    
    for (comparison in comparisonNames){
        # tabulated file with dataframe
        if (bed_file) {
            hitsFile <- paste(output_path, "tab-files/", comparison, "-all-hits-captures-BED.tab", sep="")
        } else {
            hitsFile <- paste(output_path, "tab-files/", comparison, "-window-", window_size, "-all-hits.tab", sep="")
        }
        
        # calculate Copy Number Variations (CNVs)
        cnv <- cnv.cal(hitsFile, log2=log2, annotate=annotate)
        
        # path to save images
        if (bed_file) {
            imagePath <- paste(output_path, "images/", comparison, "-chromosome-all-captures-BED.", imgType, 
                             sep="")
            if (imgType == "png") {png(imagePath)}
            else if (imgType == "svg") {svg(imagePath)}
            else if (imgType == "jpeg") {jpeg(imagePath)}
            else if (imgType == "pdf") {pdf(imagePath)}
        } else {
            imagePath <- paste(output_path, "images/", comparison, "-chromosome-all-window-", window_size, ".", imgType,
                             sep="")
            if (imgType == "png") {png(imagePath)}
            else if (imgType == "svg") {svg(imagePath)}
            else if (imgType == "jpeg") {jpeg(imagePath)}
            else if (imgType == "pdf") {pdf(imagePath)}
        }

        # plot all chromosomes' CNVs
        plotAll <- plot.cnv.all(cnv, title="Copy Number Variants - All", ylim=c(yMin,yMax), colour=2)
        plotAll <- plotAll + labs(title="CNV - All Chromosomes", 
                                  subtitle=comparison, caption=imagePath) +
                             theme(plot.title=element_text(hjust=0.5, size=16),
                                   plot.subtitle=element_text(hjust=0.5, size=14), 
                                   plot.caption=element_text(hjust=0, face="italic", size=12),
                                   axis.text.x=element_text(angle=20, vjust=1, hjust=1))
        print(plotAll)

        # save and close pdf device  
        dev.off()

        # print figure to stdout
        print(plotAll)

        # loop per chromosomes
        for (chrom in chromosomes){
            # path to save images in png format
            if (bed_file) {
                imagePath <- paste(output_path, "images/", comparison, 
                                 "-chromosome-", chrom, "-captures-BED.", imgType,
                                 sep="")
                if (imgType == "png") {png(imagePath)}
                else if (imgType == "svg") {svg(imagePath)}
                else if (imgType == "jpeg") {jpeg(imagePath)}
                else if (imgType == "pdf") {pdf(imagePath)}
            } else {
                imagePath <- paste(output_path, "images/", comparison, 
                                 "-chromosome-", chrom, "-window-", window_size, ".", imgType,
                                 sep="")
                if (imgType == "png") {png(imagePath)}
                else if (imgType == "svg") {svg(imagePath)}
                else if (imgType == "jpeg") {jpeg(imagePath)}
                else if (imgType == "pdf") {pdf(imagePath)}
            }

            # plot chromosome CNV
            plotChr <- plot.cnv.chr(cnv, chromosome=chrom, ylim=c(yMin,yMax))
            plotChrTitle <- paste("CNV -", chrom)
            plotChr <- plotChr + labs(title=plotChrTitle, 
                                      subtitle=comparison, caption=imagePath) +
                                 theme(plot.title=element_text(hjust=0.5, size=14),
                                       plot.subtitle=element_text(hjust=0.5), 
                                       plot.caption=element_text(hjust=0, face="italic"))
            print(plotChr)

            # save and close pdf device  
            dev.off()

            # print figure to stdout
            print(plotChr)
        }
    }
}

# zoom into chromosome subregion
cnvPlotZoom <- function(config, hitsTabFile, chromosome=NA, start=NA, end=NA, yMin=-5, yMax=5, imgType="png"){
    # store provided parameters
    parameters <- config$parameters
    parameterNames <- names(config$parameters)

    # first check if parameter exists. if exist, store value,
    # if not exist, use default values
    if ('annotate' %in% parameterNames){
        annotate <- config$parameters$annotate
    } else {annotate <- TRUE}
    if ('log2' %in% parameterNames){
        log2 <- config$parameters$log2
    } else {log2 <- 0.6}
    
    # calculate Copy Number Variations (CNVs) from tab file
    cnv <- cnv.cal(hitsTabFile, log2=log2, annotate=annotate)
    
    # path to save image
    imagePath <- gsub("-all-hits.tab", "", gsub("tab-files", "images", hitsTabFile))
    imagePath <- paste(imagePath, "-chromosome-", chromosome, "-zoomed.", imgType, sep="")
    
    if (imgType == "png") {png(imagePath)}
    else if (imgType == "svg") {svg(imagePath)}
    else if (imgType == "jpeg") {jpeg(imagePath)}
    else if (imgType == "pdf") {pdf(imagePath)}
    
    # plot chromosome subregion
    plotChr <- plot.cnv.chr(cnv, chromosome=chromosome, from=start, to=end, ylim=c(yMin,yMax))
    plotChrTitle <- paste("CNV -", chromosome)
    plotChr <- plotChr + labs(title=plotChrTitle, 
                              caption=imagePath) +
                         theme(plot.title=element_text(hjust=0.5, size=14),
                               plot.subtitle=element_text(hjust=0.5), 
                               plot.caption=element_text(hjust=0, face="italic"))
    print(plotChr)
    
    # save and close pdf device  
    dev.off()
    
    # print figure to stdout
    print(plotChr)
}