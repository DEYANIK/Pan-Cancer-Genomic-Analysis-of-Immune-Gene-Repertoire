library(TCGAbiolinks)
library(tidyr)
library(dplyr)
library(DESeq2)
library(RColorBrewer)
library(SummarizedExperiment)
library(ggplot2)
library(pheatmap)
library(readr)

# so my files_dir
base_dir <- "/storage1/Cancer_genome_project/Cancers"
cancer_types <- c("BRCA", "HNSC", "KIRC", "LIHC", "LUSC", "STAD", "UCEC",
                  "COAD", "KICH", "KIRP", "LUAD", "PRAD", "THCA")
cancer_dirs <- c("TCGA-BRCA_data", "TCGA-HNSC_data", "TCGA-KIRC_data",
                 "TCGA-LIHC_data", "TCGA_LUSC_data", "TCGA-STAD_data",
                 "TCGA-UCEC_data", "TCGA-COAD_data", "TCGA-KICH_data",
                 "TCGA-KIRP_data", "TCGA_LUAD_data", "TCGA-PRAD_data",
                 "TCGA-THCA_data")

# connectin the cancer dirs to the type
cancer_dir_map <- setNames(cancer_dirs, cancer_types)

# my curated gene_sets: 52gene
innate_immunity_genes <- c("CD36", "CD136", "ARG1", "NOS2", "KLRF1", "IL6", "IL10", "TGFB1", "C1QA", "IRF1") # 10gene
antigen_presentation_genes <- c("HLA-A", "HLA-B", "HLA-C", "B2M", "TAP1", "TAP2", "HLA-DRA", "CIITA", "HLA-DRB1", "HLA-DQA1" ) #10gene
T_cell_function_genes <- c("CD8A", "CD8B", "CD4", "GZMA", "GZMB", "GZMH", "PRF1", "IFNG", "TNF", "IL2", "TOX", "TBX21", "TCF7", "LEF1") #14gene
Reg_T_cell_genes <- c("FOXP3", "IL2RA", "CTLA4", "IDO1", "ENTPD1") #5gene
immune_checkpoint_genes <- c("CD28", "HAVCR2", "LAG3", "TIGIT", "PDCD1", "CD274") #6gene
TME_genes <- c("CD68", "CD163", "CSF1R", "CD14", "NCR1", "KLRK1", "STAT1") # 7gene
# combinig my gene-sets
all_immune_genes <- c(innate_immunity_genes, antigen_presentation_genes, T_cell_function_genes, Reg_T_cell_genes, immune_checkpoint_genes, TME_genes)

# Create results directory
dir.create("DESeq2_Results", showWarnings = FALSE)

#star reading, have already downloaded them from TCGA.
read_star_counts <- function(cancer_type) {
  cancer_dir <- cancer_dir_map[cancer_type]
  data_path <- file.path(base_dir, cancer_dir, paste0("TCGA-", cancer_type),
                         "Transcriptome_Profiling", "Gene_Expression_Quantification")
  
  if (!dir.exists(data_path)) return(NULL)
  
  sample_dirs <- list.dirs(data_path, recursive = FALSE, full.names = TRUE)
  count_files <- sapply(sample_dirs, function(x) {
    files <- list.files(x, pattern = "\\.tsv$", full.names = TRUE)
    if(length(files) > 0) files[1] else NA
  })
  
  count_files <- count_files[!is.na(count_files)]
  if(length(count_files) == 0) return(NULL)
  
  # clean and filtering out summary
  first_file <- read_tsv(count_files[1], comment = "#", show_col_types = FALSE)
  gene_rows <- !grepl("^N_", first_file$gene_id)
  gene_info <- first_file[gene_rows, c("gene_id", "gene_name")]
  count_matrix <- sapply(count_files, function(file) {
    data <- read_tsv(file, comment = "#", show_col_types = FALSE)
    gene_rows <- !grepl("^N_", data$gene_id)
    data_filtered <- data[gene_rows, ]
    data_filtered$unstranded[match(gene_info$gene_id, data_filtered$gene_id)]
  })
  
  # UUID extract and clean sample
  sample_names <- sapply(count_files, function(file_path) {
    filename <- basename(file_path)
    sub("\\.rna_seq.*", "", filename)
  })
  colnames(count_matrix) <- sample_names
  rownames(count_matrix) <- gene_info$gene_id
  count_matrix[is.na(count_matrix)] <- 0
  return(list(counts = count_matrix, gene_info = gene_info))
}

# load metadata
load_metadata <- function(cancer_type, sample_names) {
  metadata_file <- file.path(base_dir, paste0("TCGA_", cancer_type, "_samples.csv"))
  # if file not found
  if(!file.exists(metadata_file)) {
    cat("file not found for", cancer_type, "\n")
    return(NULL)
  }
  # Read metdata
  existing_metadata <- read.csv(metadata_file, stringsAsFactors = FALSE)
  cat("Loading metadata", cancer_type, "with", nrow(existing_metadata), "samples\n")
  metadata_uuids <- sub("\\.rna_seq.*", "", existing_metadata$file_name)
  
  # Sample UUID match
  matched_indices <- match(sample_names, metadata_uuids)
  sample_type <- existing_metadata$sample_type[matched_indices]
  cases_id <- existing_metadata$cases.submitter_id[matched_indices]
  
  # NA remove
  valid_samples <- !is.na(matched_indices)
  sample_names <- sample_names[valid_samples]
  sample_type <- sample_type[valid_samples]
  cases_id <- cases_id[valid_samples]
  

  condition <- ifelse(sample_type == "Primary Tumor", "Tumor",
                      ifelse(sample_type == "Solid Tissue Normal", "Normal", "Other"))
  
  metadata <- data.frame(
    sample_id = sample_names,
    sample_type = sample_type,
    condition = condition,
    cancer_type = cancer_type,
    cases_id = cases_id,
    stringsAsFactors = FALSE
  )
  
  cat("Matched", nrow(metadata), "samples for", cancer_type, "\n")
  cat("Sample distribution:", paste(names(table(metadata$condition)), table(metadata$condition), collapse = ", "), "\n")
  return(list(metadata = metadata, valid_samples = valid_samples))
}

# DESEQ2
perform_deseq2_analysis <- function(cancer_type) {
  cat("doing dese", cancer_type, "...\n")
  
  # data load
  data <- read_star_counts(cancer_type)
  if(is.null(data)) {
    cat("No data found for", cancer_type, "\n")
    return(NULL)
  }
  metadata_result <- load_metadata(cancer_type, colnames(data$counts))
  if(is.null(metadata_result)) return(NULL)
  metadata <- metadata_result$metadata
  valid_samples <- metadata_result$valid_samples
  data$counts <- data$counts[, valid_samples]
  keep_samples <- metadata$condition %in% c("Tumor", "Normal")
  # cuttoff
  if(sum(keep_samples) < 6) {  
    cat("Insufficient dtaa:", cancer_type, "\n")
    return(NULL)
  }
  counts_filtered <- data$counts[, keep_samples]
  metadata_filtered <- metadata[keep_samples, ]
  sample_dist <- table(metadata_filtered$condition)
  if(any(sample_dist < 3)) {
    cat("Insuff-sample", cancer_type, "\n")
    return(NULL)
  }
  rownames(metadata_filtered) <- metadata_filtered$sample_id
  metadata_filtered$condition <- factor(metadata_filtered$condition, levels = c("Normal", "Tumor"))
  dds <- DESeqDataSetFromMatrix(
    countData = round(counts_filtered),
    colData = metadata_filtered,
    design = ~ condition
  )
  keep <- rowSums(counts(dds) >= 10) >= 3
  dds <- dds[keep, ]
  dds <- DESeq(dds, quiet = TRUE)
  res <- results(dds, contrast = c("condition", "Tumor", "Normal"))
  gene_symbols <- data$gene_info$gene_name[match(rownames(res), data$gene_info$gene_id)]
  res$gene_symbol <- gene_symbols
  immune_gene_mask <- gene_symbols %in% all_immune_genes
  immune_results <- res[immune_gene_mask & !is.na(immune_gene_mask), ]
  
  # saave
  write.csv(as.data.frame(res),
            file = file.path("DESeq2_Results", paste0(cancer_type, "_all_genes_results.csv")))
  if(nrow(immune_results) > 0) {
    write.csv(as.data.frame(immune_results),
              file = file.path("DESeq2_Results", paste0(cancer_type, "_immune_genes_results.csv")))
  }
  
  return(list(
    dds = dds,
    results = res,
    immune_results = immune_results,
    metadata = metadata_filtered,
    sample_counts = sample_dist
  ))
}
results_list <- list()
summary_stats <- data.frame()
for(cancer in cancer_types) {
  result <- perform_deseq2_analysis(cancer)
  if(!is.null(result)) {
    results_list[[cancer]] <- result
    sig_genes <- sum(result$results$padj < 0.05, na.rm = TRUE)
    immune_sig <- sum(result$immune_results$padj < 0.05, na.rm = TRUE)
    summary_stats <- rbind(summary_stats, data.frame(
      Cancer_Type = cancer,
      Total_Samples = ncol(result$dds),
      Tumor_Samples = result$sample_counts["Tumor"],
      Normal_Samples = result$sample_counts["Normal"],
      Significant_Genes = sig_genes,
      Significant_Immune_Genes = immune_sig,
      Total_Immune_Genes_Found = nrow(result$immune_results)
    ))
  }
}
write.csv(summary_stats, "DESeq2_Results/analysis_summary.csv", row.names = FALSE)

# Create combined immune gene results
combine_immune_results <- function(results_list) {
  combined_results <- data.frame()
  
  for(cancer in names(results_list)) {
    if(nrow(results_list[[cancer]]$immune_results) > 0) {
      temp_df <- as.data.frame(results_list[[cancer]]$immune_results)
      temp_df$Cancer_Type <- cancer
      temp_df$Gene_ID <- rownames(temp_df)
      combined_results <- rbind(combined_results, temp_df)
    }
  }
  
  return(combined_results)
}