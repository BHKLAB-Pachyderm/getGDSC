#!/usr/bin/env Rscript

library(PharmacoGx)
library(data.table)
library(Biobase)
library(reshape2)
library(dplyr)
library(data.table)
library(reshape2)
library(CoreGx)
library(SummarizedExperiment)

options(stringsAsFactors=FALSE)
print("Retrieving selection")

myDirPrefix <- "/pfs"
args = commandArgs(trailingOnly=TRUE)
rnaseq_select <- args
print(rnaseq_select)
rnaseq_results <- list()
ORCESTRA_ID = tail(rnaseq_select, n=1)

cnv_select <-  grep('cnv', rnaseq_select)
mutation_select <-  grep('mutation', rnaseq_select)
microarray_select <-  grep('microarray', rnaseq_select)
fusion_select <-  grep('fusion', rnaseq_select)
	  
tools <- grep(pattern = 'Kallisto|Salmon', x = rnaseq_select)
tools <- rnaseq_select[tools]
tools <- gsub("-", "_", tools)
transcriptome <- grep(pattern = 'Gencode|Ensembl', x = rnaseq_select)
transcriptome <- rnaseq_select[transcriptome]
tool_path = expand.grid(a = tools,b = transcriptome)
tool_path = paste0(tool_path$a, "_",tool_path$b)
	  
print(tool_path)

version <- tail(args, n=3)[1]
drug_version <- tail(args, n=2)[1]
print(version)
print(drug_version)

standardize <- args[grep("filtered", args)]

standardizeRawDataConcRange <- function(sens.info, sens.raw){
  unq.drugs <- unique(sens.info$drugid)
  
  conc.m <- data.table(melt(sens.raw[,,1], as.is=TRUE))
  conc.m[,drugid := sens.info$drugid[match(Var1, rownames(sens.info))]]
  conc.ranges <- conc.m[,.(l = min(value, na.rm=T), r = max(value, na.rm=T)), c("drugid", "Var1")]
  conc.ranges[,Var1 := NULL]
  conc.ranges <- conc.ranges[,unique(.SD), drugid]	
  # conc.ranges[,N := .N, drugid]
  conc.ranges.disj <- conc.ranges[, {sq <- sort(unique(c(l,r))); 
  l = sq[seq(1,length(sq)-1)];
  r = sq[seq(2,length(sq))];
  .(l=l,r=r)}, drugid]
  ## Function below returns all consecutive ranges of ints between 1 and N
  returnConsInts <- function(N) {
    stopifnot(N>0)
    unlist(sapply(seq(1,N), function(ii) return(sapply(seq(ii, N), function(jj) return(seq(ii,jj))))), recursive=FALSE)
  }
  rangeNoHoles <- function(indicies, lr.tbl){
    if(length(indicies) == 1) return(TRUE)
    sq <- seq(indicies[1], indicies[length(indicies)]-1)
    all(lr.tbl[["l"]][sq+1] <= lr.tbl[["r"]][sq])
  }
  per.drug.range.indicies <- sapply(conc.ranges.disj[,.N,drugid][,N], returnConsInts)
  
  names(per.drug.range.indicies) <- conc.ranges.disj[,unique(drugid)] ## checked this: conc.ranges.disj[,.N,drugid][,drugid] == conc.ranges.disj[,unique(drugid)]
  
  
  # Check if there are any holes in the chosen range combination
  per.drug.range.indicies <- sapply(names(per.drug.range.indicies), function(drug){
    
    lr.tbl <- conc.ranges.disj[drugid == drug]
    per.drug.range.indicies[[drug]][sapply(per.drug.range.indicies[[drug]], rangeNoHoles, lr.tbl = lr.tbl)]
    
  })
  per.drug.range.indicies.2 <- sapply(names(per.drug.range.indicies), function(drug){
    
    lr.tbl <- conc.ranges.disj[drugid == drug]
    res <- t(sapply(per.drug.range.indicies[[drug]], function(x) return(c(lr.tbl[x[1],l], lr.tbl[x[length(x)],r]))))
    colnames(res) <- c("l", "r")
    res <- data.frame(res)
    res <- cbind(drugid = drug, res)
  }, simplify=FALSE)
  per.drug.range.indicies.dt <- rbindlist(per.drug.range.indicies.2)
  
  conc.ranges <- conc.m[,.(l = min(value, na.rm=T), r = max(value, na.rm=T)), c("drugid", "Var1")]
  setkey(conc.m, Var1)
  conc.m <- na.omit(conc.m)
  setkey(conc.m, drugid, Var1, value)
  setkey(conc.ranges, drugid, l, r)
  # tic()
  ## NOTE:: Data.table used for maximum speed. Probably possible to do this more intelligently by 
  ## NOTE:: being aware of which conditions overlap, but its fast enough right now as it is.
  chosen.drug.ranges <- lapply(unq.drugs, function(drug){
    num.points.in.range <- apply(per.drug.range.indicies.dt[drugid==drug, .(l,r)], 1, function(rng){
      conc.m[drugid==drug][conc.ranges[drugid==drug][l<=rng["l"]][r>=rng["r"],Var1], on="Var1"][value >= rng["l"]][value <= rng["r"],.N]
      # conc.m[drugid==drug][, Var1]
    })
    max.ranges <- per.drug.range.indicies.dt[drugid==drug][which(num.points.in.range==max(num.points.in.range))]
    max.ranges[which.max(log10(r) - log10(l)), ]
  })
  # toc()
  names(chosen.drug.ranges) <- sapply(chosen.drug.ranges, `[[`, "drugid")
  removed.experiments <- unlist(lapply(unq.drugs, function(drug){
    rng <- unlist(chosen.drug.ranges[[drug]][,.(l,r)])
    exp.out.range <- conc.ranges[drugid==drug][l>rng["l"] | r<rng["r"],Var1]
    return(exp.out.range)
  }))
  
  sens.raw[removed.experiments,,] <- NA_real_
  conc.ranges.kept <- conc.ranges[!Var1 %in% removed.experiments]
  
  for(drug in unq.drugs){
    rng <- unlist(chosen.drug.ranges[[drug]][,.(l,r)])
    myx <- conc.ranges.kept[drugid==drug,Var1]
    doses <- sens.raw[myx, ,"Dose"]
    which.remove <- (doses < rng["l"] | doses > rng["r"])
    sens.raw[myx, ,"Dose"][which(which.remove,arr.ind=TRUE)] <- NA_real_
    sens.raw[myx, ,"Viability"][which(which.remove,arr.ind=TRUE)] <- NA_real_
    
    ## Annotate sens info with chosen range
    sens.info[sens.info$drugid==drug,"chosen.min.range"] <- rng["l"]
    sens.info[sens.info$drugid==drug,"chosen.max.range"] <- rng["r"]
  }
  sens.info$rm.by.conc.range <- FALSE
  sens.info[removed.experiments,"rm.by.conc.range"] <- TRUE
  
  return(list("sens.info" = sens.info, sens.raw = sens.raw))
}


#filter noisy curves from PSet (modified function to take into account standardized conc range)
filterNoisyCurves2 <- function(pSet, epsilon=25 , positive.cutoff.percent=.80, mean.viablity=200, nthread=1) {
  acceptable <- mclapply(rownames(sensitivityInfo(pSet)), function(xp) {
    #for(xp in rownames(sensitivityInfo(pSet))){
    drug.responses <- as.data.frame(apply(pSet@sensitivity$raw[xp , ,], 2, as.numeric), stringsAsFactors=FALSE)
    if (!all(is.na(drug.responses))){
      
      
      drug.responses <- drug.responses[complete.cases(drug.responses), ]
      doses.no <- nrow(drug.responses)
      drug.responses[,"delta"] <- .computeDelta(drug.responses$Viability)
      
      delta.sum <- sum(drug.responses$delta, na.rm = TRUE)
      
      max.cum.sum <- .computeCumSumDelta(drug.responses$Viability)
      
      if ((table(drug.responses$delta < epsilon)["TRUE"] >= (doses.no * positive.cutoff.percent)) &
          (delta.sum < epsilon) &
          (max.cum.sum < (2 * epsilon)) &
          (mean(drug.responses$Viability) < mean.viablity)) {
        return (xp)
      }
    }
    
  }, mc.cores=nthread)
  acceptable <- unlist(acceptable)
  noisy <- setdiff(rownames(sensitivityInfo(pSet)), acceptable)
  return(list("noisy"=noisy, "ok"=acceptable))
}

.computeDelta <- function(xx ,trunc = TRUE) {
  xx <- as.numeric(xx)
  if(trunc)
  {
    return(c(pmin(100, xx[2:length(xx)]) - pmin(100, xx[1:length(xx)-1]), 0))
  }else{
    return(c(xx[2:length(xx)] - xx[1:length(xx)-1]), 0)
  }
}

#' @importFrom utils combn
.computeCumSumDelta <- function(xx, trunc = TRUE) {
  xx <- as.numeric(xx)
  if(trunc) {
    xx <- pmin(xx, 100)
  }
  tt <- t(combn(1:length(xx), 2 , simplify = TRUE))
  tt <- tt[which(((tt[,2] - tt[,1]) >= 2) == TRUE),]
  if (is.null(nrow(tt))){
    tt <- matrix(tt, ncol = 2)
  }
  cum.sum <- unlist(lapply(1:nrow(tt), function(x){xx[tt[x,2]]-xx[tt[x,1]]}))
  return(max(cum.sum))
}   

matchToIDTable <- function(ids,tbl, column, returnColumn="unique.cellid") {
	sapply(ids, function(x) {
                          myx <- grep(paste0("((///)|^)",Hmisc::escapeRegex(x),"((///)|$)"), tbl[,column])
                          if(length(myx) > 1){
                            stop("Something went wrong in curating ids, we have multiple matches")
                          }
			  if(length(myx) == 0){return(NA_character_)}
                          return(tbl[myx, returnColumn])
                        })
}


switch(version, v1 = {
	myOutFile <- "GDSC_v1.RData"
	myInPrefix <- "gdscv1"
  sensFolder <- "GDSC2019v1Normalize"
  profFolder <- "gdscProfilesV1"

	}, v2 = {
	myOutFile <- "GDSC_v2.RData"
	myInPrefix <- "gdscv2"
  sensFolder <- "GDSC2019v2Normalize"
  profFolder <- "gdscprofilesV2"

	})

switch(drug_version, "8.0" = {
  Name <- ""
  
}, "8.2" = {
  Name <- "_8.2"
})

cell_all <- read.csv("/pfs/downAnnotations/cell_annotation_all.csv", na.strings=c("", " ", "NA"))

message("Loading Sensitivity Data")

sens.info <- readRDS(file=file.path(myDirPrefix, sensFolder, paste0(myInPrefix, "_sens_info", Name,".rds")))
sens.raw <- readRDS(file=file.path(myDirPrefix, sensFolder, paste0(myInPrefix, "_sens_raw", Name, ".rds")))
rownames(sens.info) <- sens.info$exp_id
rownames(sens.raw) <- sens.info$exp_id

# sens.recalc <- PharmacoGx:::.calculateFromRaw(sens.raw, nthread=10)

# saveRDS(sens.recalc, file=paste0(myInPrefix, "_sens_recalc.rds"))

# sens.recalc <- readRDS(paste0(myInPrefix, "_sens_recalc.rds"))
# sens.recalc$pars <- lapply(sens.recalc$pars, unlist)

# sens.pars <- do.call(rbind, sens.recalc$pars)

# sens.profiles <- cbind(data.frame("AAC" = sens.recalc$AUC, "IC50" = sens.recalc$IC50), sens.pars)

load(file.path(myDirPrefix, profFolder,  paste0("profiles",Name,".RData")))

sens.profiles <- res

sens.profiles <- sens.profiles[rownames(sens.info),]

message("Loading RNA Data")

load(file.path(myDirPrefix, "gdscU133a_normalized/GDSC_U133a_ENSG.RData"))

cell.all <- read.csv(file.path(myDirPrefix, "downAnnotations/cell_annotation_all.csv"))

cgp.u133a.ensg@phenoData@data$Characteristics.CellLine.[grep("MZ2-MEL.", cgp.u133a.ensg@phenoData@data$Characteristics.CellLine.)] <- c("MZ2-MEL","MZ2-MEL")
rna.cellid <- as.character(matchToIDTable(ids=cgp.u133a.ensg@phenoData@data$Characteristics.CellLine., tbl=cell_all, column = "CGP.cellid", returnColumn="unique.cellid"))
pData(cgp.u133a.ensg)[,"cellid"] <- rna.cellid


message("Loading CNV Data")


#load(file.path(myDirPrefix, "gdscCNA/GDSC_eset.RData"))
cl.eset <- readRDS("/pfs/gdsc_cnv_new/GDSC_CN.gene.RDS")
y <- ExpressionSet(cl.eset@assayData$exprs) #remove other assays for now (nAraw, nBraw, nMajor, nMinor, TCN), as SummarizeMolecularProfiles does not support multi-assays
pData(y) <- cl.eset@phenoData@data
cl.eset <- y
cl.eset$GDSC.cellid <- as.character(cl.eset$`Sample Name`)
cnv.cellid <- as.character(matchToIDTable(ids=cl.eset$GDSC.cellid, tbl=cell.all, column="GDSC.SNP.cellid", returnColumn = "unique.cellid"))


#myx <- which(is.na(cl.eset$GDSC.cellid))

#toRep <- cl.eset$GDSC.cellid
#toRep[myx] <- sapply(strsplit(rownames(phenoData(cl.eset))[myx], split="_"), `[`, 1)

#cl.eset$GDSC.cellid <- toRep

# phenoData(cl.eset)[myx,"GDSC.cellid"] <- sapply(strsplit(rownames(phenoData(cl.eset))[myx], split="_"), `[`, 1)

#cnv.cellid <- matchToIDTable(ids=cl.eset$GDSC.cellid, tbl=cell.all, column="GDSC.SNP.cellid", returnColumn = "unique.cellid")

message("Loading Mutation/fusion Data")


mut.matrix <- read.csv(file.path(myDirPrefix, "gdscMutPanel/gdsc_mutation_w5.csv"))

mut.cellid <- matchToIDTable(ids=mut.matrix[,1], tbl=cell.all, column="CGP.cellid", returnColumn = "unique.cellid")


rangeg <- which(colnames(mut.matrix) == "AKT2"):which(colnames(mut.matrix) == "VHL")

mutation <- as.matrix(mut.matrix[ , rangeg, drop=FALSE])
mutation <- apply(X=mutation, MARGIN=c(1, 2), FUN=function(x) {
    x <- unlist(strsplit(x, split="::"))
    if(length(x) == 2) {
      if(!is.na(x[[1]]) && (x[[1]] == "na")) {
        x <- NA
      } else {
        x <- x[[1]]
      }
    } else { x <- NA }
    return(x)
  })

MutationEset <- ExpressionSet(t(mutation)) 

colnames(MutationEset) <- mut.cellid

load("/pfs/downAnnotations/Ensembl.v99.annotation.RData")
geneMap <- features_gene

geneInfoM <- geneMap[na.omit(match(rownames(MutationEset),geneMap[ , "gene_name"]) ), c("gene_id", "gene_name", "gene_biotype")] 
rownames(geneInfoM) <- geneInfoM[ , "gene_name"]     
geneInfoM <- geneInfoM[rownames(MutationEset),]
colnames(geneInfoM) <- c("EnsemblGeneId", "Symbol", "GeneBioType")
rownames(geneInfoM) <- rownames(MutationEset)
fData(MutationEset) <- geneInfoM 
tttt <- data.frame(row.names=colnames(MutationEset), colnames(MutationEset))
colnames(tttt) <- 'cellid'
pData(MutationEset) <- tttt
pData(MutationEset)[, "batchid"] <- NA
annotation(MutationEset) <- "mutation"



rangefus <- which(colnames(mut.matrix) == "BCR_ABL"):which(colnames(mut.matrix) == "MLL_AFF1")

fusion <- as.matrix(mut.matrix[ , rangefus, drop=FALSE])
fusion <- apply(X=fusion, MARGIN=c(1, 2), FUN=function(x) {
    # x <- unlist(strsplit(x, split="::"))
    if(x == "") {
        x <- NA
      } else if (x == "0"){
        x <- "wt"
      }
    return(x)
  })



FusionEset <- ExpressionSet(t(fusion)) 

colnames(FusionEset) <- mut.cellid
tttt <- data.frame(row.names=colnames(FusionEset), colnames(FusionEset))
colnames(tttt) <- 'cellid'
pData(FusionEset) <- tttt
annotation(FusionEset) <- "fusion"
pData(FusionEset)[, "batchid"] <- NA


message("Loading Cell and Drug Info")


load(file.path(myDirPrefix, paste0("gdsc1000CellInfo/","cellInfo", Name,".RData")))
load(file.path(myDirPrefix, paste0("gdscDrugInfo/","drugInfo", Name,".RData")))


rownames(cell.info) <- cell.info$unique.cellid


summarizeRnaSeq <- function (dir, 
                             features_annotation,
                             samples_annotation,
			      method) {
  library(Biobase)
  library(readr)
  library(tximport)
  
  load(features_annotation)
    
  tx2gene <- as.data.frame(cbind("transcript"=tx2gene$transcripts, "gene"=tx2gene$genes))
  
  files <- list.files(dir, recursive = TRUE, full.names = T)
  if(method=="kallisto"){
  resFiles <- grep("abundance.h5", files)
  }else{
  resFiles <- grep("quant.sf", files)
  }
  resFiles <- files[resFiles]
  length(resFiles)
  names(resFiles) <- basename(dirname(resFiles))
  
  if(features_annotation == "/pfs/downAnnotations/Ensembl.v99.annotation.RData"){
  txi <- tximport(resFiles, type=method, tx2gene=tx2gene, ignoreAfterBar = TRUE, ignoreTxVersion = TRUE)
  } else{
  txi <- tximport(resFiles, type=method, tx2gene=tx2gene, ignoreAfterBar = TRUE, ignoreTxVersion = FALSE)	  
  }
	  
  head(txi$counts[,1:5])
  dim(txi$counts)
	  
  xx <- txi$abundance
  gene.exp <- Biobase::ExpressionSet(log2(xx + 0.001))
  fData(gene.exp) <- features_gene[featureNames(gene.exp),]
  pData(gene.exp) <- samples_annotation[sampleNames(gene.exp),]
  annotation(gene.exp) <- "rnaseq"
  
  xx <- txi$counts
  gene.count <- Biobase::ExpressionSet(log2(xx + 1))
  fData(gene.count) <- features_gene[featureNames(gene.count),]
  pData(gene.count) <- samples_annotation[sampleNames(gene.count),]
  annotation(gene.count) <- "rnaseq"
  
  txii <- tximport(resFiles, type=method, txOut=T)
  
  if(features_annotation == "/pfs/downAnnotations/Ensembl.v99.annotation.RData"){
  #remove non-coding transcripts in ensembl 	  
  rownames(txii$abundance) <-  gsub("\\..*","",rownames(txii$abundance))
  txii$abundance[which(!rownames(txii$abundance)  %in% features_transcript$transcript_id)]
  missing_transcript <- rownames(txii$abundance)[which(!rownames(txii$abundance)  %in% features_transcript$transcript_id)]
  txii$abundance <- txii$abundance [-which(rownames(txii$abundance) %in% missing_transcript),]
  }
  	  
  xx <- txii$abundance
  transcript.exp <- Biobase::ExpressionSet(log2(xx[,1:length(resFiles)] + 0.001))
  if(features_annotation == "/pfs/downAnnotations/Gencode.v33.annotation.RData" || features_annotation == "/pfs/downAnnotations/Gencode.v33lift37.annotation.RData"){
  featureNames(transcript.exp) <- gsub("\\|.*","",featureNames(transcript.exp))
  fData(transcript.exp) <- features_transcript[featureNames(transcript.exp),]
  }else{
  fData(transcript.exp) <- features_transcript[featureNames(transcript.exp),]
  }
  pData(transcript.exp) <- samples_annotation[sampleNames(transcript.exp),]
  annotation(transcript.exp) <- "isoform"
  
	  
  if(features_annotation == "/pfs/downAnnotations/Ensembl.v99.annotation.RData"){
  #remove non-coding transcripts in ensembl
  rownames(txii$counts) <-  gsub("\\..*","",rownames(txii$counts))
  txii$counts <- txii$counts [-which(rownames(txii$counts) %in% missing_transcript),]	  
  }	  
  xx <- txii$counts
  transcript.count <- Biobase::ExpressionSet(log2(xx[,1:length(resFiles)] + 1))
  if(features_annotation == "/pfs/downAnnotations/Gencode.v33.annotation.RData" || features_annotation == "/pfs/downAnnotations/Gencode.v33lift37.annotation.RData"){
  featureNames(transcript.count) <- gsub("\\|.*","",featureNames(transcript.count))
  fData(transcript.count) <- features_transcript[featureNames(transcript.count),]
  }else{
  fData(transcript.count) <- features_transcript[featureNames(transcript.count),]
  }
  pData(transcript.count) <- samples_annotation[sampleNames(transcript.count),]
  annotation(transcript.count) <- "isoform"
	
	
  pData(gene.exp)[ ,"batchid"] <- NA
  pData(gene.count)[ ,"batchid"] <- NA	  
  pData(transcript.exp)[ ,"batchid"] <- NA
  pData(transcript.count)[ ,"batchid"] <- NA
  
  return(list("rnaseq"=gene.exp, 
              "rnaseq.counts"=gene.count, 
              "isoforms"=transcript.exp, 
              "isoforms.counts"=transcript.count))
}

rnaseq.sampleinfo <- read.csv("/pfs/downAnnotations/GDSC_rnaseq_meta.txt", sep="\t")
rnaseq.sampleinfo <- rnaseq.sampleinfo[which(!rnaseq.sampleinfo$Comment.SUBMITTED_FILE_NAME. == "15552_5.cram"),]
rownames(rnaseq.sampleinfo) <- rnaseq.sampleinfo$Comment.EGA_RUN.
rnaseq.sampleinfo$cellid <- matchToIDTable(ids=rnaseq.sampleinfo$Source.Name, tbl=cell.all, column = "GDSC_rnaseq.cellid", returnColumn = "unique.cellid")
#rnaseq.sampleinfo <- rnaseq.sampleinfo[,c("cellid","Characteristics.organism.part.","Characteristics.disease.","Characteristics.sex.","Scan.Name","Comment.EGA_RUN.")]
   
for (r in 1:length(tool_path)){
  print(tool_path[r])
  if (length(grep(pattern = 'Kallisto', x = tool_path[r])) > 0){
    tool <- sub("(_[^_]+)_.*", "\\1", tool_path[r])
    tdir = paste0("gdsc_rnaseq_",gsub(".","_",tolower(tool), fixed = T), "/",  tool, "/", tool, "/")  
    rnatool="kallisto"	  
  } else {
    tool <- sub("(_[^_]+)_.*", "\\1", tool_path[r])
    tdir = paste0("gdsc_rnaseq_",gsub(".","_",tolower(tool), fixed = T), "/",  tool, "/", tool, "/")
    rnatool="salmon"	  
  }
  
  
  if (length(grep(pattern = 'lift37', x = tool_path[r])) > 0){
    annot = "/pfs/downAnnotations/Gencode.v33lift37.annotation.RData"
  } else if (length(grep(pattern = 'v33', x = tool_path[r])) > 0){
    annot = "/pfs/downAnnotations/Gencode.v33.annotation.RData"
  } else {
    annot = "/pfs/downAnnotations/Ensembl.v99.annotation.RData"
  }
    print(annot)
  
 
  rnaseq <- summarizeRnaSeq(dir=file.path(paste0("/pfs/", tdir, tool_path[r])),
                            features_annotation=annot,
                            samples_annotation=rnaseq.sampleinfo,
			    method = rnatool)
  rnaseq_results <- c(rnaseq_results,c(
    rnaseq <- setNames(rnaseq,  paste0(tool,".", names(rnaseq)))
  )
  )
}

message("Compile All GDSC Mutation Data")

######### Loading ALL exome data #########
mutation_raw <- read.csv("/pfs/gdscmutation_all/mutations_latest.csv", na.strings=c("", " ", "NA"))
mutation_raw <- mutation_raw[,c("gene_symbol","protein_mutation","model_name","cancer_driver")]
mutation_raw <- mutation_raw[which(mutation_raw$cancer_driver=="True"),]
cells_matched <- matchToIDTable(ids = mutation_raw[,3], tbl = cell.all, column = "GDSC.SNP.cellid", returnColumn = "unique.cellid")
mutation_raw[,3] <- as.character(cells_matched)
mutation_raw$cancer_driver <- NULL

#concatenate cases where one cell line maps to the same gene twice ("///")
xx <- mutation_raw %>% group_by(gene_symbol, model_name) %>% 
  mutate(protein_mutation = paste(protein_mutation, collapse="///"))

xx_df <- data.frame(xx)

#removes duplicated concatenation
xx_df_2 <- distinct(xx_df,gene_symbol, model_name,.keep_all = TRUE)

#flatten data frame to gene name x cell line matrix
matrix_final <- reshape2::acast(xx_df_2, gene_symbol ~ model_name, value.var = "protein_mutation")
matrix_final[which(is.na(matrix_final))] <- "wt"


geneInfoM <- geneMap[na.omit(match(rownames(matrix_final),geneMap[ , "gene_name"])), c("gene_id", "gene_name", "gene_biotype")] 
rownames(geneInfoM) <- geneInfoM[ , "gene_name"] 
missing_genes <- rownames(matrix_final)[which(!rownames(matrix_final) %in% geneMap$gene_name)]
all_genes <- c(rownames(geneInfoM), missing_genes)
geneInfoM[nrow(geneInfoM)+ length(missing_genes),] <- NA
rownames(geneInfoM) <- all_genes

geneInfoM <- geneInfoM[rownames(matrix_final),] 
colnames(geneInfoM) <- c("EnsemblGeneId", "Symbol", "GeneBioType")

MutationAll <- Biobase::ExpressionSet(matrix_final)
tttt <- data.frame(row.names=colnames(MutationAll), colnames(MutationAll))
colnames(tttt) <- 'cellid'
pData(MutationAll) <- tttt
fData(MutationAll) <- geneInfoM 
annotation(MutationAll) <- "mutation"
pData(MutationAll)[, "batchid"] <- NA


rnaseq_cellid_all <- pData(rnaseq_results[[1]])[,"cellid"]
cellnall <- CoreGx::.unionList(rownames(cell.info), 
					  cnv.cellid, 
					  rna.cellid, 
					  mut.cellid,
		     			  rnaseq_cellid_all,
		     			  MutationAll$cellid)
newcells <- setdiff(cellnall, rownames(cell.info))
newRows <- matrix(NA_character_, nrow=length(newcells), ncol=ncol(cell.info))
# newRows <- cell.info[newcells,]

rownames(newRows) <- newcells
colnames(newRows) <- colnames(cell.info)
newRows[,"unique.cellid"] <- newcells

cell.info <- rbind(cell.info, newRows)

collapseRows2 <- function(x, rows){
    xNew <- lapply(x[rows, ], function(x) {
      xx <- na.omit(x)
      if (length(xx) == 0) {
        xx <- NA
      }
      if (length(unique(xx)) > 1) {
        xx <- paste(xx, collapse="///")
      } else {xx <- xx[1]}
      return(as.vector(xx))
      })
    xNew <- as.data.frame(xNew, as.is = TRUE)
    x[rows[1], ] <- xNew
    x <- x[-rows[-1], ]
    return(x)
  }

message("Deduplicating Drugs")


drugDupsIDs <- unique(drug.info$unique.drugid[duplicated(drug.info$unique.drugid)])

for(dupID in drugDupsIDs){
	myx <- which(drug.info$unique.drugid == dupID)
	drug.info <- collapseRows2(drug.info, myx)
}
rownames(drug.info) <- drug.info$unique.drugid

message("Making Curation Tables")

curationCell <- data.frame(unique.cellid = rownames(cell.info),
						   GDSC2019.cellid = cell.info$Sample.Name,
						   CGP.cellid = NA_character_,
						   GDSC.SNP.cellid = NA_character_,
						   CGP_EMTAB3610.cellid = NA_character_,
			  			   GDSC_rnaseq.cellid = NA_character_,
			  		           GDSC1000.cellid = NA_character_)
rownames(curationCell) <- curationCell$unique.cellid

myx <- match(rownames(curationCell),cell.all$unique.cellid)

curationCell$CGP.cellid <- cell.all[myx, "CGP.cellid"]
curationCell$GDSC.SNP.cellid <- cell.all[myx, "GDSC.SNP.cellid"]
curationCell$CGP_EMTAB3610.cellid <- cell.all[myx, "CGP_EMTAB3610.cellid"]
curationCell$GDSC_rnaseq.cellid <- cell.all[myx, "GDSC_rnaseq.cellid"]
curationCell$GDSC1000.cellid <- cell.all[myx, "GDSC1000.cellid"]

cell.info$tissueid <- cell.all[myx, "unique.tissueid"]

curationTissue <- data.frame("unique.tissueid" = cell.info$tissueid, "GDSC2019.tissueid" = cell.info$GDSC..Tissue.descriptor.1)
rownames(curationTissue) <- rownames(cell.info)

curationDrug <- data.frame(unique.drugid = drug.info$unique.drugid,
						   "GDSC2019.drugid" = drug.info$DRUG_NAME)
rownames(curationDrug) <- rownames(drug.info)

annot <- geneMap
rownames(annot) <- annot$gene_id
#gdsc.u219.ensg <- cgp.u219.ensg
#annotation(gdsc.u219.ensg) <- "rna"
#ensemblIds <- sapply(strsplit(rownames(exprs(gdsc.u219.ensg)), "_"), function (x) { return (x[[1]]) }) 
#fData(gdsc.u219.ensg) <- data.frame("Probe"=rownames(exprs(gdsc.u219.ensg)), 
                          #"EnsemblGeneId"=ensemblIds,
                          #"Symbol"=annot[ensemblIds, "gene_name"],
                          #"GeneBioType"=annot[ensemblIds, "gene_biotype"],
                          #"BEST"=TRUE)
#rownames(fData(gdsc.u219.ensg)) <- rownames(exprs(gdsc.u219.ensg))
#pData(gdsc.u219.ensg)[,"batchid"] <- NA
#pData(gdsc.u219.ensg)[,"cellid"] <- rna.cellid

#Compile CNV data

tt <- rownames(pData(cl.eset))
pData(cl.eset) <- as.data.frame(apply(pData(cl.eset), MARGIN=2, as.character), stringsAsFactors=FALSE)
rownames(pData(cl.eset)) <- tt
pData(cl.eset)[,"batchid"] <- NA
pData(cl.eset)[,"cellid"] <- cnv.cellid
pData(cl.eset) <- pData(cl.eset)[,c("cellid","batchid")]
tt <- annot[match(rownames(fData(cl.eset)), geneMap$gene_name), c("gene_id", "gene_name", "gene_biotype")]
rownames(tt) <- rownames(fData(cl.eset))
colnames(tt) <- c("EnsemblGeneId", "Symbol", "GeneBioType")
fData(cl.eset) <- tt
annotation(cl.eset) <- "cnv"


cellsPresent <- sort(CoreGx::.unionList(sens.info$cellid, 
					  pData(cgp.u133a.ensg)$cellid, 
					  pData(MutationEset)$cellid,
					  pData(FusionEset)$cellid,
					  pData(cl.eset)$cellid,
		    			  rnaseq_cellid_all,
			      		  MutationAll$cellid))
cell.info <- cell.info[cellsPresent,]
cell.info$tissueid <- curationTissue[rownames(cell.info), "unique.tissueid"]

drugsPresent <- sort(unique(sens.info$drugid))

drug.info <- drug.info[drugsPresent,]


drug_all <- read.csv("/pfs/downAnnotations/drugs_with_ids.csv", na.strings=c("", " ", "NA"))
drug_all <- drug_all[which(!is.na(drug_all[ , "GDSC2019.drugid"])),]
drug_all <- drug_all[ , c("unique.drugid", "GDSC2019.drugid","smiles","inchikey","cid","FDA")]
rownames(drug_all) <- drug_all[ , "unique.drugid"]

drug_all <- drug_all[rownames(drug.info),]
drug.info[,c("smiles","inchikey","cid","FDA")] <- drug_all[,c("smiles","inchikey","cid","FDA")]
drug.info$GDSC2019.drugid <- NULL
colnames(drug.info)[which(names(drug.info) == "unique.drugid")] <- "drugid"

curationDrug <- curationDrug[rownames(drug.info),]

message("Making PSet")


if (length(cnv_select) > 0){
  cnv_cells_id <- cl.eset$cellid
} else {
  cnv_cells_id <- c()
  cl.eset <- ExpressionSet()
  pData(cl.eset)$cellid <- character()
  pData(cl.eset)$batchid <- character()
  fData(cl.eset)$BEST <- vector()
  fData(cl.eset)$Symbol <- character()
  annotation(cl.eset) <- "CNV data was not selected for on ORCESTRA"
}
		 
if (length(mutation_select) > 0){
  mutation_cells_id <- c(MutationEset$cellid, MutationAll$cellid)
} else {
  mutation_cells_id <- c()
  MutationEset <-  ExpressionSet()
  pData(MutationEset)$cellid <- character()
  pData(MutationEset)$batchid <- character()
  fData(MutationEset)$BEST <- vector()
  fData(MutationEset)$Symbol <- character()
  annotation(MutationEset) <- "Mutation data was not selected for on ORCESTRA"
	
  MutationAll <-  ExpressionSet()
  pData(MutationAll)$cellid <- character()
  pData(MutationAll)$batchid <- character()
  fData(MutationAll)$BEST <- vector()
  fData(MutationAll)$Symbol <- character()
  annotation(MutationAll) <- "Mutation data was not selected for on ORCESTRA"
}
		 
if (length(microarray_select) > 0){
  microarray_cells_id <- cgp.u133a.ensg$cellid
} else {
  microarray_cells_id <- c()
  cgp.u133a.ensg <- ExpressionSet()
  pData(cgp.u133a.ensg)$cellid <- character()
  pData(cgp.u133a.ensg)$batchid <- character()
  fData(cgp.u133a.ensg)$BEST <- vector()
  fData(cgp.u133a.ensg)$Symbol <- character()
  annotation(cgp.u133a.ensg) <- "Microarray data was not selected for on ORCESTRA"
}
		 
if (length(fusion_select) > 0){
  fusion_cells_id <- FusionEset$cellid
} else {
  fusion_cells_id <- c()
  FusionEset <- ExpressionSet()
  pData(FusionEset)$cellid <- character()
  pData(FusionEset)$batchid <- character()
  fData(FusionEset)$BEST <- vector()
  fData(FusionEset)$Symbol <- character()
  annotation(FusionEset) <- "Fusion data was not selected for on ORCESTRA"
}	 
		 
z <- list()

z <- c(z,c(
  rnaseq_results,
  "rna"=cgp.u133a.ensg, 
  "mutation"=MutationEset, 
  "mutation_exome"=MutationAll,
  "fusion"=FusionEset, 
  "cnv"=cl.eset
  )
)		 

.converteSetToSE <- function(eSets) {
  
  SEfinal <- lapply(eSets,
         function(eSet){
             # Change rownames from probes to EnsemblGeneId for rna data type
             if (grepl("^rna$", Biobase::annotation(eSet))) {
               rownames(eSet) <- Biobase::fData(eSet)$EnsemblGeneId
             }
             
             # Build summarized experiment from eSet
             SE <- SummarizedExperiment::SummarizedExperiment(
               ## TODO:: Do we want to pass an environment for better memory efficiency?
               assays=S4Vectors::SimpleList(as.list(Biobase::assayData(eSet))
               ),
               # Switch rearrange columns so that IDs are first, probes second
               rowData=S4Vectors::DataFrame(Biobase::fData(eSet),
                                            rownames=rownames(Biobase::fData(eSet)) 
               ),
               colData=S4Vectors::DataFrame(Biobase::pData(eSet),
                                            rownames=rownames(Biobase::pData(eSet))
               ),
               metadata=list("experimentData" = eSet@experimentData, 
                             "annotation" = Biobase::annotation(eSet), 
                             "protocolData" = Biobase::protocolData(eSet)
               )
             )
             ## TODO:: Determine if this can be done in the SE constructor?
             # Extract names from expression set
             SummarizedExperiment::assayNames(SE) <- Biobase::assayDataElementNames(eSet)
             mDataType <- Biobase::annotation(eSet)
             eSets[[mDataType]] <- SE
         })
  #setNames(pSet@molecularProfiles, names(eSets))
  return(SEfinal)
}
		 
z <- .converteSetToSE(z)
		 
#add cellosaurus disease type to cell-info
		 
colnames(cell.info)[which(names(cell.info) == "unique.cellid")] <- "cellid"
disease <- cell_all$Cellosaurus.Disease.Type[match(cell.info$cellid, cell_all$unique.cellid)]
cell.info$Cellosaurus.Disease.Type <- disease		 

#add cellosaurus assession to cell-info
assession <- cell_all$Cellosaurus.Accession.id[match(cell.info$cellid, cell_all$unique.cellid)]
cell.info$Cellosaurus.Accession.id <- assession
		 
#add pharmacodb id to cell-info
pdb <- cell_all$PharmacoDB.id[match(cell.info$cellid, cell_all$unique.cellid)]
cell.info$PharmacoDB.id <- pdb

#add study tissue id to cell_info
study_tissue <- cell_all$unique.tissueid.fromstudies[match(cell.info$cellid, cell_all$unique.cellid)]
cell.info$unique.tissueid.fromstudies <- study_tissue
		 
#add study cell-line type to cell_info
cell_type <- cell_all$CellLine.Type[match(cell.info$cellid, cell_all$unique.cellid)]
cell.info$CellLine.Type <- cell_type
		 
#add metastatic info to cell_info		 
metastatic <- cell_all$Metastatic[match(cell.info$cellid, cell_all$unique.cellid)]
cell.info$Metastatic <- metastatic		 
curationCell <- curationCell[rownames(cell.info),]
curationTissue <- curationTissue[rownames(cell.info),]
		 
cells_keep <- unique(c(rnaseq_cellid_all, sens.info$cellid, cnv_cells_id, mutation_cells_id, microarray_cells_id, fusion_cells_id))
		 
cell.info <- cell.info[cells_keep,]
curationCell <- curationCell[cells_keep,]
curationTissue <- curationTissue[cells_keep,]

if (length(standardize) > 0){

# standardize <- standardizeRawDataConcRange(sens.info = sens.info, sens.raw = sens.raw)
# sens.info <- standardize$sens.info
# sens.raw <- standardize$sens.raw

} else {
print("unfiltered PSet")
	
}
	     
	     
GDSC <- PharmacoGx::PharmacoSet(molecularProfiles=z,
                      name=paste("GDSC", version, sep="_"), 
                      cell=cell.info, 
                      drug=drug.info, 
                      sensitivityInfo=sens.info, 
                      sensitivityRaw=sens.raw, 
                      sensitivityProfiles=sens.profiles, 
                      sensitivityN=NULL, 
                      curationCell=curationCell, 
                      curationDrug=curationDrug, 
                      curationTissue=curationTissue, 
                      datasetType="sensitivity")

if (length(standardize) > 0){

 noisy_out <- filterNoisyCurves2(GDSC)
 print("filter done")
 GDSC@sensitivity$profiles[noisy_out$noisy, ] <- NA

} else {
print("unfiltered PSet")
	
}
	     
GDSC@annotation$version <- 2		 

saveRDS(GDSC, file=paste0("/pfs/out/GDSC", gsub("v", "",version), ".rds"), version=2)
		 
dataset <- paste0("GDSC", gsub("v", "",version))
		 
#output ORCESTRA_ID and Pachyderm commit id
write.table(dataset, file="/pfs/out/dataset.txt", row.names = F ,quote = F, sep = "\t", col.names = F)
write.table(ORCESTRA_ID, file="/pfs/out/orcestra_id.txt", row.names = F ,quote = F, sep = "\t", col.names = F)				   
pach_commit_id <- Sys.getenv("PACH_OUTPUT_COMMIT_ID")
write.table(pach_commit_id, file="/pfs/out/commit_id.txt", row.names = F ,quote = F, sep = "\t", col.names = F) 
