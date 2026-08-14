#!/usr/bin/env ruby
# frozen_string_literal: true

# K-Dense Science Lab — a team of agents, ported from paperclipai/companies
# (companies/kdense-science-lab).
#
# A team is just agents wired together: the company definition stays in
# the verbatim upstream markdown (COMPANY.md and agents/*/AGENTS.md, with
# each member's skills under agents/<name>/.brute/skills); this file
# only does the wiring. Reporting lines come from each agent's
# `reportsTo` frontmatter — every agent is a Brute::Tools::SubAgent in
# its manager's tool list, reproducing the company's org chart:
#
#   ceo  (get-available-resources, offer-k-dense-web)
#   └─► chief-science-officer  (perplexity-search, parallel-web)
#       ├─► bio-genomics-lead  (biopython, scanpy)
#       │   ├─► genomics-analyst  (pysam, tiledbvcf, gget, polars-bio, pydeseq2)
#       │   ├─► phylogenetics-specialist  (phylogenetics, etetoolkit, scikit-bio, biopython)
#       │   ├─► regulatory-genomics-analyst  (arboreto, geniml, adaptyv, zarr-python, aeon)
#       │   ├─► sequencing-analyst  (deeptools, flowio, bioservices, gtars)
#       │   └─► single-cell-specialist  (anndata, scvelo, scvi-tools, cellxgene-census, scanpy)
#       ├─► clinical-research-lead  (clinical-decision-support, primekg)
#       │   ├─► clinical-data-scientist  (pyhealth, clinical-reports, treatment-plans, iso-13485-certification)
#       │   ├─► clinical-trials-specialist  (clinicaltrials-database, cbioportal-database, neurokit2)
#       │   ├─► histopathology-analyst  (pathml, histolab, pydicom, imaging-data-commons)
#       │   ├─► neuroinformatics-analyst  (neuropixels-analysis, neurokit2, pydicom, imaging-data-commons)
#       │   └─► precision-medicine-analyst  (clinvar-database, clinpgx-database, cosmic-database, depmap)
#       ├─► data-viz-lead  (matplotlib, exploratory-data-analysis)
#       │   ├─► geospatial-analyst  (geopandas, geomaster, networkx)
#       │   ├─► statistical-analyst  (statistical-analysis, exploratory-data-analysis, datacommons-client)
#       │   └─► visualization-specialist  (plotly, seaborn, matplotlib, scientific-visualization)
#       ├─► databases-lead  (pubmed-database, openalex-database)
#       │   ├─► biomedical-db-specialist  (reactome-database, kegg-database, hmdb-database, brenda-database, monarch-database)
#       │   ├─► chemistry-db-specialist  (chembl-database, pubchem-database, drugbank-database, zinc-database, bindingdb-database)
#       │   ├─► genomics-db-specialist  (ensembl-database, gene-database, gnomad-database, geo-database, gtex-database, gwas-database)
#       │   ├─► literature-db-specialist  (arxiv-database, biorxiv-database, openalex-database, pubmed-database)
#       │   ├─► proteomics-db-specialist  (alphafold-database, pdb-database, uniprot-database, interpro-database, string-database)
#       │   └─► regulatory-db-specialist  (fda-database, uspto-database, ena-database, jaspar-database, metabolomics-workbench-database, opentargets-database)
#       ├─► drug-discovery-lead  (rdkit, datamol)
#       │   ├─► cheminformatics-scientist  (rdkit, molfeat, medchem, datamol, deepchem)
#       │   ├─► drug-screening-analyst  (pytdc, torchdrug, matchms, pyopenms)
#       │   └─► molecular-docking-specialist  (diffdock, molecular-dynamics, rowan, esm)
#       ├─► financial-research-lead  (edgartools, fred-economic-data)
#       │   └─► quantitative-analyst  (alpha-vantage, hedgefundmonitor, usfiscaldata, denario)
#       ├─► lab-ops-lead  (benchling-integration, open-notebook)
#       │   ├─► lab-automation-engineer  (opentrons-integration, pylabrobot, ginkgo-cloud-lab, protocolsio-integration)
#       │   └─► lab-informatics-specialist  (labarchive-integration, lamindb, dnanexus-integration, latchbio-integration, omero-integration, modal)
#       ├─► ml-lead  (scikit-learn, pytorch-lightning)
#       │   ├─► deep-learning-engineer  (pytorch-lightning, transformers, torch-geometric, umap-learn)
#       │   ├─► forecasting-analyst  (timesfm-forecasting, statsmodels, vaex, scikit-learn)
#       │   ├─► optimization-scientist  (pymoo, simpy, dask, polars)
#       │   ├─► rl-engineer  (stable-baselines3, pufferlib, pytorch-lightning)
#       │   └─► statistical-modeler  (pymc, statsmodels, scikit-survival, shap)
#       ├─► physical-sciences-lead  (sympy, astropy)
#       │   ├─► biochemistry-specialist  (cobrapy, glycoengineering, dhdna-profiler)
#       │   ├─► computational-physicist  (fluidsim, sympy, matlab, astropy)
#       │   ├─► materials-scientist  (pymatgen, cobrapy, glycoengineering)
#       │   └─► quantum-computing-scientist  (qiskit, cirq, pennylane, qutip)
#       ├─► research-methods-lead  (hypothesis-generation, scientific-brainstorming)
#       │   ├─► critical-analysis-specialist  (scientific-critical-thinking, consciousness-council, what-if-oracle, scholar-evaluation)
#       │   └─► hypothesis-engineer  (hypogenic, dhdna-profiler, hypothesis-generation, scientific-brainstorming)
#       └─► sci-comm-lead  (scientific-writing, peer-review)
#           ├─► document-specialist  (docx, pdf, xlsx, markitdown, paper-2-web, markdown-mermaid-writing)
#           ├─► manuscript-writer  (scientific-writing, writing, latex-posters, venue-templates, citation-management)
#           ├─► market-research-analyst  (market-research-reports, scientific-schematics, scholar-evaluation)
#           ├─► presentation-designer  (scientific-slides, pptx, pptx-posters, generate-image, infographics)
#           └─► research-intelligence-analyst  (bgpt-paper-search, literature-review, research-lookup, research-grants, pyzotero)
#
# Usage:
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/ports/paperclip/kdense-science-lab/team.rb \
#     "<task for the team>"

require "bundler/setup"
require "brute"

MODEL = "claude-sonnet-4-20250514"

# Strip YAML frontmatter from an upstream markdown file, returning
# [frontmatter_hash, body].
def load_agent_md(path)
  raw = File.read(path)
  parts = raw.split(/^---\s*$/, 3)
  [YAML.safe_load(parts[1]), parts[2].strip]
end

def agent_dir(name) = File.join(__dir__, "agents", name)

# Build one team member as a SubAgent: verbatim AGENTS.md body as its
# system prompt, its own skills dir, the working tools, and its direct
# reports (if any) as callable sub-agents.
def member(name, description, reports: [])
  _meta, body = load_agent_md(File.join(agent_dir(name), "AGENTS.md"))

  prompt = Brute::SystemPrompt.build do |p, ctx|
    p << body
    skills = Brute::Prompts::Skills.call(ctx.merge(cwd: agent_dir(name)))
    p << skills if skills
    unless reports.empty?
      p << "Your direct reports are available as tools — call one to " \
           "delegate, passing the full task context."
    end
  end

  Brute::Tools::SubAgent.new(
    name:        name,
    description: description,
    provider:    Brute.provider,
    model:       MODEL,
    tools:       Brute::Tools::ALL + reports,
  ) do
    use Brute::Middleware::EventHandler,
        handler_class: Brute::Events::PrefixedTerminalOutput, prefix: name
    use Brute::Middleware::SystemPrompt, system_prompt: prompt
    use Brute::Middleware::ToolResultLoop
    use Brute::Middleware::MaxIterations
    use Brute::Middleware::ToolCall
    run Brute::Middleware::Completion::RubyLLM.new
  end
end

# The org chart, leaves first, so each manager can reference its reports.
# Descriptions come from each agent's "Where work comes from" /
# "What triggers you" section (or its opening paragraph).
genomics_analyst = member("genomics-analyst",
           "Genomics Analyst — Variant calling and genotype analysis tasks; BAM/VCF " \
           "file processing needs; Gene query and annotation requests; Large-scale " \
           "genomic data processing")

phylogenetics_specialist = member("phylogenetics-specialist",
           "Evolutionary Genomics Specialist — Phylogenetic tree construction tasks; " \
           "Evolutionary relationship analysis; Sequence alignment and homology " \
           "studies; Species divergence and molecular clock analyses")

regulatory_genomics_analyst = member("regulatory-genomics-analyst",
           "Regulatory Genomics Analyst — Gene regulatory network inference tasks; " \
           "Functional element analysis; Protein engineering and directed evolution " \
           "data; Large-scale array data processing")

sequencing_analyst = member("sequencing-analyst",
           "Sequencing Data Analyst — Sequencing quality control tasks; Epigenomic " \
           "data analysis (ChIP-seq, ATAC-seq); Flow cytometry data processing; " \
           "Sequence database queries")

single_cell_specialist = member("single-cell-specialist",
           "Single-Cell Omics Specialist — Single-cell RNA-seq analysis tasks; Cell " \
           "type identification and clustering needs; Trajectory and velocity " \
           "analysis; Atlas-scale single-cell queries")

bio_genomics_lead = member("bio-genomics-lead",
           "Director of Bioinformatics & Genomics — Genomics and bioinformatics " \
           "requests from the CSO; Sequence analysis, gene expression, or variant " \
           "calling needs; Single-cell experiment design and analysis; Evolutionary " \
           "and phylogenetic studies",
           reports: [genomics_analyst, phylogenetics_specialist, regulatory_genomics_analyst, sequencing_analyst, single_cell_specialist])

clinical_data_scientist = member("clinical-data-scientist",
           "Clinical Data Scientist — Patient data analysis tasks; Clinical report " \
           "generation needs; Treatment plan design requests; Medical device quality " \
           "compliance")

clinical_trials_specialist = member("clinical-trials-specialist",
           "Clinical Trials Specialist — Clinical trial search and analysis tasks; " \
           "Cancer genomics data queries; Biomarker discovery needs; Trial design " \
           "support")

histopathology_analyst = member("histopathology-analyst",
           "Histopathology Analyst — Whole slide image analysis tasks; Tissue " \
           "classification and segmentation needs; Pathology image preprocessing; " \
           "Medical imaging dataset queries")

neuroinformatics_analyst = member("neuroinformatics-analyst",
           "Neuroinformatics Analyst — Neuropixels and electrophysiology analysis " \
           "tasks; EEG, ECG, EMG signal processing needs; Medical imaging data " \
           "processing; Brain imaging dataset queries")

precision_medicine_analyst = member("precision-medicine-analyst",
           "Precision Medicine Analyst — Variant interpretation tasks; " \
           "Pharmacogenomics analysis requests; Cancer mutation profiling needs; " \
           "Functional genomics screen analysis")

clinical_research_lead = member("clinical-research-lead",
           "Director of Clinical Research — Clinical research and patient data " \
           "analysis requests from the CSO; Precision medicine and pharmacogenomics " \
           "inquiries; Clinical trial data review needs; Medical imaging analysis " \
           "tasks",
           reports: [clinical_data_scientist, clinical_trials_specialist, histopathology_analyst, neuroinformatics_analyst, precision_medicine_analyst])

geospatial_analyst = member("geospatial-analyst",
           "Geospatial Data Analyst — Geospatial data processing tasks; Map " \
           "generation and spatial analysis; Network and graph analysis needs; " \
           "Location-based data queries")

statistical_analyst = member("statistical-analyst",
           "Statistical Analyst — Statistical hypothesis testing tasks; Exploratory " \
           "data analysis needs; Public dataset queries; Data quality assessment " \
           "requests")

visualization_specialist = member("visualization-specialist",
           "Visualization Specialist — Publication figure generation tasks; " \
           "Interactive dashboard creation; Data visualization design needs; Complex " \
           "multi-panel figure composition")

data_viz_lead = member("data-viz-lead",
           "Director of Data Analysis & Visualization — Data visualization and " \
           "figure generation requests; Statistical analysis needs from any " \
           "department; Exploratory data analysis tasks; Geospatial data processing " \
           "needs",
           reports: [geospatial_analyst, statistical_analyst, visualization_specialist])

biomedical_db_specialist = member("biomedical-db-specialist",
           "Biomedical Database Specialist — Biological pathway queries; Enzyme " \
           "kinetics data retrieval; Metabolite identification needs; Disease-gene " \
           "association lookups")

chemistry_db_specialist = member("chemistry-db-specialist",
           "Chemistry Database Specialist — Compound property lookup tasks; " \
           "Drug-target interaction queries; Chemical library searches; Bioactivity " \
           "data retrieval")

genomics_db_specialist = member("genomics-db-specialist",
           "Genomics Database Specialist — Gene annotation and information queries; " \
           "Population variant frequency lookups; Gene expression dataset searches; " \
           "GWAS and genetic association queries")

literature_db_specialist = member("literature-db-specialist",
           "Literature Database Specialist — Literature search tasks; Preprint " \
           "monitoring needs; Citation analysis requests; Scholarly metadata queries")

proteomics_db_specialist = member("proteomics-db-specialist",
           "Proteomics Database Specialist — Protein structure lookup tasks; " \
           "Protein-protein interaction queries; Domain and functional site " \
           "searches; Protein sequence annotation needs")

regulatory_db_specialist = member("regulatory-db-specialist",
           "Regulatory & Patent Database Specialist — FDA approval and drug label " \
           "queries; Patent search tasks; Regulatory sequence database queries; " \
           "Specialized biological database needs")

databases_lead = member("databases-lead",
           "Director of Scientific Databases — Database query requests from any " \
           "department; Data integration needs across multiple databases; Bulk data " \
           "retrieval tasks; Cross-reference and annotation needs",
           reports: [biomedical_db_specialist, chemistry_db_specialist, genomics_db_specialist, literature_db_specialist, proteomics_db_specialist, regulatory_db_specialist])

cheminformatics_scientist = member("cheminformatics-scientist",
           "Cheminformatics Scientist — Molecular property calculation tasks; SAR " \
           "analysis and lead optimization; Chemical library curation; Molecular " \
           "featurization for ML")

drug_screening_analyst = member("drug-screening-analyst",
           "Drug Screening Analyst — Virtual screening campaign tasks; Compound " \
           "library analysis; Mass spectrometry data processing; Drug discovery " \
           "benchmark evaluations")

molecular_docking_specialist = member("molecular-docking-specialist",
           "Molecular Docking Specialist — Protein-ligand docking tasks; Molecular " \
           "dynamics simulation needs; Binding pose prediction; Protein structure " \
           "analysis")

drug_discovery_lead = member("drug-discovery-lead",
           "Director of Drug Discovery — Drug discovery and molecular design " \
           "requests from the CSO; Hit-to-lead optimization tasks; Virtual screening " \
           "campaigns; ADMET property assessments",
           reports: [cheminformatics_scientist, drug_screening_analyst, molecular_docking_specialist])

quantitative_analyst = member("quantitative-analyst",
           "Quantitative Financial Analyst — Market data retrieval tasks; Economic " \
           "indicator analysis; Financial performance tracking; Government fiscal " \
           "data queries")

financial_research_lead = member("financial-research-lead",
           "Director of Financial Research — Financial analysis requests related to " \
           "biotech and scientific markets; SEC filing reviews for competitor " \
           "intelligence; Economic indicator analysis; Funding and investment " \
           "research",
           reports: [quantitative_analyst])

lab_automation_engineer = member("lab-automation-engineer",
           "Lab Automation Engineer — Lab protocol automation tasks; Liquid handling " \
           "robot programming; Cloud lab experiment submission; Protocol sharing and " \
           "documentation")

lab_informatics_specialist = member("lab-informatics-specialist",
           "Lab Informatics Specialist — LIMS integration tasks; Data management and " \
           "lineage tracking; Cloud compute job submission; Imaging data management")

lab_ops_lead = member("lab-ops-lead",
           "Director of Laboratory Operations — Laboratory automation and protocol " \
           "design requests; LIMS and data management integration needs; Instrument " \
           "control and robotics tasks; Electronic notebook and data lineage needs",
           reports: [lab_automation_engineer, lab_informatics_specialist])

deep_learning_engineer = member("deep-learning-engineer",
           "Deep Learning Engineer — Neural network architecture design tasks; NLP " \
           "and language model tasks for science; Graph neural network needs; " \
           "Dimensionality reduction for visualization")

forecasting_analyst = member("forecasting-analyst",
           "Forecasting Analyst — Time series forecasting tasks; Trend detection and " \
           "seasonal analysis; Large-scale temporal data processing; Predictive " \
           "modeling for longitudinal studies")

optimization_scientist = member("optimization-scientist",
           "Optimization Scientist — Multi-objective optimization tasks; Process " \
           "simulation and modeling; Large-scale data processing needs; Parallel " \
           "computation design")

rl_engineer = member("rl-engineer",
           "Reinforcement Learning Engineer — Reinforcement learning environment " \
           "design tasks; Agent training and policy optimization; Scientific control " \
           "and decision-making problems; Game-theoretic modeling needs")

statistical_modeler = member("statistical-modeler",
           "Statistical Modeler — Bayesian modeling tasks; Survival and " \
           "time-to-event analysis; Model interpretability requests; Advanced " \
           "statistical inference needs")

ml_lead = member("ml-lead",
           "Director of Machine Learning — ML model building requests from the CSO; " \
           "Predictive modeling and classification tasks; Statistical analysis " \
           "needing advanced methods; Model interpretability and explanation " \
           "requests",
           reports: [deep_learning_engineer, forecasting_analyst, optimization_scientist, rl_engineer, statistical_modeler])

biochemistry_specialist = member("biochemistry-specialist",
           "Biochemistry Specialist — Metabolic pathway modeling tasks; Glycobiology " \
           "and glycoengineering needs; DNA profiling and characterization; " \
           "Biochemical network analysis")

computational_physicist = member("computational-physicist",
           "Computational Physicist — Fluid dynamics simulation tasks; Mathematical " \
           "modeling and symbolic computation; Astronomical data analysis; Numerical " \
           "computation needs")

materials_scientist = member("materials-scientist",
           "Materials Scientist — Crystal structure analysis tasks; Materials " \
           "property prediction needs; Phase diagram calculations; Metabolic network " \
           "modeling")

quantum_computing_scientist = member("quantum-computing-scientist",
           "Quantum Computing Scientist — Quantum algorithm design tasks; Quantum " \
           "simulation needs; Quantum machine learning experiments; Quantum system " \
           "dynamics modeling")

physical_sciences_lead = member("physical-sciences-lead",
           "Director of Physical Sciences — Physics, chemistry, and quantum " \
           "computing requests from the CSO; Materials design and analysis tasks; " \
           "Mathematical modeling needs; Computational simulation requests",
           reports: [biochemistry_specialist, computational_physicist, materials_scientist, quantum_computing_scientist])

critical_analysis_specialist = member("critical-analysis-specialist",
           "Critical Analysis Specialist — Critical evaluation of research claims; " \
           "Multi-perspective deliberation needs; Counterfactual scenario analysis; " \
           "Research quality assessment tasks")

hypothesis_engineer = member("hypothesis-engineer",
           "Hypothesis Engineer — Novel hypothesis generation tasks; Experimental " \
           "design brainstorming; Literature-driven hypothesis formation; DNA and " \
           "molecular profiling needs")

research_methods_lead = member("research-methods-lead",
           "Director of Research Methodology — Hypothesis formulation and validation " \
           "requests; Critical review of experimental designs; Brainstorming " \
           "sessions for new research directions; Counterfactual and what-if " \
           "analysis needs",
           reports: [critical_analysis_specialist, hypothesis_engineer])

document_specialist = member("document-specialist",
           "Document Production Specialist — Document generation tasks (Word, PDF, " \
           "Excel); Format conversion needs; Technical document creation; Diagram " \
           "and flowchart generation")

manuscript_writer = member("manuscript-writer",
           "Manuscript Writer — Manuscript writing and editing tasks; Citation " \
           "formatting needs; Journal submission preparation; Poster content writing")

market_research_analyst = member("market-research-analyst",
           "Market Research Analyst — Market research report generation tasks; " \
           "Scientific impact evaluation needs; Technical schematic creation; " \
           "Competitive landscape analysis")

presentation_designer = member("presentation-designer",
           "Presentation Designer — Presentation slide creation tasks; Conference " \
           "poster design needs; Scientific illustration requests; Infographic " \
           "generation")

research_intelligence_analyst = member("research-intelligence-analyst",
           "Research Intelligence Analyst — Systematic literature review tasks; " \
           "Grant opportunity searches; Research trend analysis needs; Reference " \
           "management tasks")

sci_comm_lead = member("sci-comm-lead",
           "Director of Scientific Communication — Manuscript and paper writing " \
           "requests; Presentation and poster needs; Document generation tasks; " \
           "Literature review and grant writing needs",
           reports: [document_specialist, manuscript_writer, market_research_analyst, presentation_designer, research_intelligence_analyst])

chief_science_officer = member("chief-science-officer",
           "Chief Science Officer — Research requests routed from the CEO; " \
           "Cross-departmental project coordination needs; Quality review of " \
           "research outputs; New capability assessments",
           reports: [bio_genomics_lead, clinical_research_lead, data_viz_lead, databases_lead, drug_discovery_lead, financial_research_lead, lab_ops_lead, ml_lead, physical_sciences_lead, research_methods_lead, sci_comm_lead])

TEAM = [chief_science_officer].freeze

# The Chief Executive Officer's prompt is the company description (COMPANY.md body)
# plus its own AGENTS.md, both verbatim.
_company_meta, company_body = load_agent_md(File.join(__dir__, "COMPANY.md"))
_root_meta, root_body       = load_agent_md(File.join(agent_dir("ceo"), "AGENTS.md"))

ROOT_PROMPT = Brute::SystemPrompt.build do |p, ctx|
  p << company_body
  p << root_body
  skills = Brute::Prompts::Skills.call(ctx.merge(cwd: agent_dir("ceo")))
  p << skills if skills
  p << "Your direct reports are available as tools — call one to delegate, " \
       "passing the full task context. Synthesize their results before " \
       "replying to the user."
end

root = Brute::Agent.new(
  provider: Brute.provider,
  model:    MODEL,
  tools:    TEAM,
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: ROOT_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new
end

request = ARGV.join(" ")
request = "Introduce the team: who's on it and what can each member do?" if request.empty?

session = Brute::Session.new
session.user(request)
root.call(session)
