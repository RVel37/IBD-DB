
# entire server module in one file -
# this is currently ignored in main.R but may be helpful
# for debugging


box::use(
  shiny[...],dplyr[...],lobstr[...],
  plotly[...],DT[...],
  dplyr[...], grid[...],
  ggplot2[...],UpSetR[...],
)

box::use(app/logic/dataTransform[exps,degs])

#'@export
server <- function(id, data){
  moduleServer(id, function(input, output, session) {
 
  # Print memory usage to console every 2000ms
  observe({
    invalidateLater(2000, session)
    print(lobstr::mem_used() / 1e6)
  },
  priority = 1000)
  
  # Reactive link to study
  output$studyLink <- renderUI({
    study <- input$selectStudy
    
    helpText(
      "View study ",
      a(study, href = paste0(GEO_BASE, study), target = "_blank"),
      " on GEO."
    )
  })
  
  # Reactive contrast selector
  output$UIselectContrast <- renderUI({
    study <- input$selectStudy
    cont_labels <- deg_contrasts %>%
      dplyr::filter(study_id == study) %>% 
      unite("contrast", c("numerator", "denominator"), sep = " vs. ") %>% 
      pull(contrast)
    
    selectInput(
      inputId = "selectContrast",
      label = "Contrast (Numerator vs. Denominator)",
      selected = cont_labels[1],
      choices = cont_labels
    )
  })

  # DEG results table
  output$degTable <- DT::renderDT(server = TRUE, {
    req(input$selectStudy, input$selectContrast)
    study <- input$selectStudy
    pair <- strsplit(input$selectContrast, " vs. ")[[1]]
    
    degs[[study]] %>%
      dplyr::filter(numerator == pair[[1]] & denominator == pair[[2]]) %>% 
      select(gene_name, logFC, FDR) %>% 
      mutate(
        gene_name = paste0(
          "<a href='", paste0(GENECARDS_BASE, gene_name),
          "' target='_blank'>", gene_name, "</a>"
        )
      ) %>%
      DT::datatable(
        selection = list(mode = "single", selected = 1),
        rownames = FALSE, escape = FALSE,
        colnames = c("Gene", "Fold Change (log2)", "Adjusted p-value"),
        options = list(pageLength = 8, scrollX = TRUE)
      ) %>% 
      DT::formatSignif(2:3, digits = 5)
  })
  
  # Get currently-selected gene from DEG results table
  current_gene <- reactive({
    req(input$selectStudy, input$selectContrast)
    study <- input$selectStudy
    pair <- strsplit(input$selectContrast, " vs. ")[[1]]
    
    # Get selected row from datatable
    selectedRow <- ifelse(
      is.null(input$degTable_rows_selected), 1, input$degTable_rows_selected
    )
    
    gene <- degs[[study]] %>%
      dplyr::filter(numerator == pair[[1]] & denominator == pair[[2]]) %>% 
      dplyr::filter(row_number() == selectedRow) %>%
      pull(gene_name)
  })
  
  # Expression plot
  output$countplot <- plotly::renderPlotly({
    req(input$selectStudy, input$selectCTS, current_gene())
    study <- input$selectStudy
    cts_sel <- input$selectCTS
    gene <- current_gene()
    
    plt <- exps[[study]][[tolower(cts_sel)]] %>%
      dplyr::filter(gene_name == gene) %>% 
      pivot_longer(
        !gene_name,
        names_to = "sample_id",
        values_to = tolower(cts_sel)
      ) %>% 
      rename(expression = tolower(cts_sel)) %>% 
      left_join(
        metadata %>% select(sample_id, condition),
        by = c("sample_id")
      ) %>% 
      ggplot(
        aes(x = condition, y = expression, fill = condition)
      ) +
      geom_boxplot(width = .65, alpha = .6, outlier.shape = NA) +
      geom_jitter(width = .15) +
      xlab("Conditions of Samples") +
      ylab(paste0("Expression (", cts_sel, ")")) +
      theme_gray(base_size = 13) +
      ggtitle(gene) +
      theme(legend.position = "none")
    
    plotly::ggplotly(plt)
  })
  
  # Volcano plot
  output$volcanoPlot <- renderPlot({
    req(input$selectStudy, input$selectContrast, current_gene())
    study <- input$selectStudy
    pair <- strsplit(input$selectContrast, " vs. ")[[1]]
    gene <- current_gene()
    
    toplt <- degs[[study]] %>%
      dplyr::filter(numerator == pair[[1]] & denominator == pair[[2]]) %>% 
      rename(padj = FDR, fc = logFC)
    
    req(!is.na(toplt$padj[1]))
    
    plot_title <- paste0(pair[1], " vs. ", pair[2])
    pltdata <- toplt %>%
      mutate(
        hlight = gene_name == gene,
        padj = case_when(
          padj == 0 ~ .Machine$double.xmin, TRUE ~ padj
        ),
        padj = -log10(padj),
        sigcond = case_when(
          padj < 2 ~ "n.s.",
          abs(fc) < 1 ~ "sig-only",
          fc > 1 ~ "Over-expressed",
          fc < -1 ~ "Under-expressed"
        )
      ) %>%
      arrange(hlight, desc(padj)) 
    maxval <- max(pltdata$padj)
    pltdata %>%
      ggplot(
        aes(x = fc, y = padj, color = sigcond, size = hlight)
      ) +
      geom_vline(xintercept = 1, linetype = "dashed", alpha = .25) +
      geom_vline(xintercept = -1, linetype = "dashed", alpha = .25) +
      geom_hline(yintercept = 3, linetype = "dashed", alpha = .25) +
      geom_point() +
      xlab("Log2 Fold Change") +
      ylab("-log10(Adjusted p-value)") +
      guides(size = guide_none(),
             color = guide_legend(title = NULL)) +
      theme_bw(base_size = 18) + 
      scale_y_continuous(expand = c(0,0), limits = c(0, 1.05 * maxval)) +
      ggtitle(plot_title, subtitle = gene) +
      scale_color_manual(
        values = c(
          "n.s." = "#d6d6d6",
          "sig-only" = "#91bac4",
          "Over-expressed" = "#2fa4c2",
          "Under-expressed" = "#c24e2f"
        )
      ) + 
      theme(legend.position = "bottom", legend.text = element_text(size = 16)) 
  })
  
  # Heatmap
  output$heatmap <- renderPlot({
    req(input$selectStudy, input$selectContrast, input$selectCTS2)
    study <- input$selectStudy
    pair <- strsplit(input$selectContrast, " vs. ")[[1]]
    cts_sel <- input$selectCTS2
    
    toplt <- degs[[study]] %>% 
      rename(padj = FDR, fc = logFC)
    
    req(!is.na(toplt$padj[1]))
    
    plot_title <- paste0(pair[1], " vs. ", pair[2])
    g2plt <- toplt %>%
      mutate(sigcond = case_when(
        padj > 0.05 ~ "n.s.",
        abs(fc) < 1 ~ "sig-only",
        fc > 1 ~ "Over-expressed",
        fc < -1 ~ "Under-expressed"
      )) %>%
      dplyr::filter(sigcond %in% c("Over-expressed", "Under-expressed")) %>% 
      group_by(sigcond) %>% 
      slice_min(order_by = padj, n = 12) %>%
      pull(gene_name)
    
    topvt <- exps[[study]][[tolower(cts_sel)]] %>%
      dplyr::filter(gene_name %in% g2plt) %>% 
      pivot_longer(
        !gene_name,
        names_to = "sample_id",
        values_to = tolower(cts_sel)
      ) %>% 
      rename(counts = tolower(cts_sel)) %>% 
      left_join(
        metadata %>% select(sample_id, condition),
        by = c("sample_id")
      ) %>%
      dplyr::filter(grepl(pair[1], condition) | grepl(pair[2], condition))
    
    annot <- topvt %>% 
      dplyr::select(sample_id, condition) %>% 
      unique() %>% 
      column_to_rownames("sample_id") %>%
      mutate(condition = case_when(  # Combine NAFLD if selected
        pair[1] == "NAFLD" & grepl("NAFLD", condition) ~ "NALFD",
        TRUE ~ condition
      ))
    
    mat <- pivot_wider(  
      data = topvt,
      id_cols = gene_name, names_from = sample_id, values_from = counts
    ) %>% 
      column_to_rownames("gene_name") %>% 
      as.matrix()
    
    req(dim(mat)[1] != 0)
    
    ann_colors <- c("red", "blue")
    names(ann_colors) <- annot %>% pull(condition) %>% unique()
    ann_colors <- list(condition = ann_colors)
    
    plt <- pheatmap(mat,
                    scale = "row",
                    angle_col = "45",
                    annotation_col = annot,
                    annotation_colors = ann_colors,
                    name = cts_sel,
                    main = plot_title
    )
    
    plt
  })
  
  # Enrichr results
  output$enrichPlot <- renderPlot({
    req(input$selectStudy, input$selectContrast, input$selectEM)
    study <- input$selectStudy
    pair <- strsplit(input$selectContrast, " vs. ")[[1]]
    colby <- input$selectEM
    
    plot_title <- paste0(pair[1], " vs. ", pair[2])
    eres_group <- paste0(study, "_", pair[1], "_", pair[2])
    
    pltdat <- eres[[eres_group]]
    
    req(pltdat)
    
    topick <- pltdat %>% 
      group_by(group) %>% 
      slice_max(Combined.Score, n = 10) %>% pull(Term)
    
    mat <- pltdat %>% 
      dplyr::filter(Term %in% topick) %>% 
      mutate(
        `Padj (-log10)`=-log10(Adjusted.P.value)
      ) %>% 
      rename(
        colby = contains(colby)
      ) %>% 
      pivot_wider(
        id_cols = Term, names_from = group, 
        values_from = colby,
        values_fill = 0
      ) %>% 
      column_to_rownames("Term") %>% 
      as.matrix()
    
    req(dim(mat)[1] != 0)
    
    pheatmap(mat,
             # scale = "col",
             angle_col = "45",
             name = colby,
             main = plot_title
    )
  })
  
  # Comparison
  output$upset <- renderPlot({
    req(input$upsetSelect)
    deg_type <- input$upsetSelect
    studies <- metadata %>% pull(study_id) %>% unique()
    
    tolist <- lapply(studies, function(study) {
      degs[[study]] %>%
        dplyr::filter(!is.na(FDR) & FDR < .01 & abs(logFC) > 1) %>%
        mutate(
          group = case_when(
            logFC > 0 ~ "Over-expressed",
            TRUE ~ "Under-expressed"
          ),
          set_name = paste0(study, "\n", numerator, " vs. ", denominator)
        ) %>%
        dplyr::filter(group == deg_type) %>% 
        select(gene_name, set_name)
    }) %>% bind_rows()
    
    all_set_names <- tolist %>% pull(set_name) %>% unique()
    names(all_set_names) <- all_set_names
    set2genes <- lapply(all_set_names, function(set_name){
      tolist %>% 
        dplyr::filter(set_name == !!set_name) %>% 
        pull(gene_name)
    })
    
    m <- make_comb_mat(set2genes)
    
    UpSet(m, row_names_gp = grid::gpar(fontsize = 10))
  })
  
  
  ## Downloads
  output$downloadLinks <- DT::renderDT({
    tibble(
      File = c(
        "metadata.csv",
        "contrasts.csv",
        "GSE126848_degs.csv.gz", 
        "GSE135251_degs.csv.gz",
        "GSE126848_gene_exp.csv.gz",
        "GSE135251_gene_exp.csv.gz",
        "enrichr_res.csv.gz"
      )
    ) %>% 
      mutate(
        Download = paste0(
          "<a href='",
          paste0(S3_HTTPS, File), 
          "' target='_blank'>link</a>"
        ) 
      ) %>%
      DT::datatable(
        selection = list(mode = "none"),
        rownames = FALSE, escape = FALSE, options = list(dom = 't')
      )
  })
  })
}
