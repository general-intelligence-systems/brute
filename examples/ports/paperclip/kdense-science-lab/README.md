# K-Dense Science Lab

A multi-disciplinary scientific research institute powered by 177 specialized skills spanning bioinformatics, drug discovery, clinical research, machine learning, quantum computing, and 37 scientific databases. A **team of 54 agents**, ported from
**[paperclipai/companies](https://github.com/paperclipai/companies)**
([`kdense-science-lab`](https://github.com/paperclipai/companies/tree/main/kdense-science-lab)). Authored upstream by K-Dense Inc..

The company definition is verbatim upstream markdown — `COMPANY.md` and the
`agents/*/AGENTS.md` role definitions, plus each member's skills.
`team.rb` only does the wiring: reporting lines come from each agent's
`reportsTo` frontmatter, with every agent a `Brute::Tools::SubAgent` in its
manager's tool list.

```
ceo  (get-available-resources, offer-k-dense-web)
└─► chief-science-officer  (perplexity-search, parallel-web)
    ├─► bio-genomics-lead  (biopython, scanpy)
    │   ├─► genomics-analyst  (pysam, tiledbvcf, gget, polars-bio, pydeseq2)
    │   ├─► phylogenetics-specialist  (phylogenetics, etetoolkit, scikit-bio, biopython)
    │   ├─► regulatory-genomics-analyst  (arboreto, geniml, adaptyv, zarr-python, aeon)
    │   ├─► sequencing-analyst  (deeptools, flowio, bioservices, gtars)
    │   └─► single-cell-specialist  (anndata, scvelo, scvi-tools, cellxgene-census, scanpy)
    ├─► clinical-research-lead  (clinical-decision-support, primekg)
    │   ├─► clinical-data-scientist  (pyhealth, clinical-reports, treatment-plans, iso-13485-certification)
    │   ├─► clinical-trials-specialist  (clinicaltrials-database, cbioportal-database, neurokit2)
    │   ├─► histopathology-analyst  (pathml, histolab, pydicom, imaging-data-commons)
    │   ├─► neuroinformatics-analyst  (neuropixels-analysis, neurokit2, pydicom, imaging-data-commons)
    │   └─► precision-medicine-analyst  (clinvar-database, clinpgx-database, cosmic-database, depmap)
    ├─► data-viz-lead  (matplotlib, exploratory-data-analysis)
    │   ├─► geospatial-analyst  (geopandas, geomaster, networkx)
    │   ├─► statistical-analyst  (statistical-analysis, exploratory-data-analysis, datacommons-client)
    │   └─► visualization-specialist  (plotly, seaborn, matplotlib, scientific-visualization)
    ├─► databases-lead  (pubmed-database, openalex-database)
    │   ├─► biomedical-db-specialist  (reactome-database, kegg-database, hmdb-database, brenda-database, monarch-database)
    │   ├─► chemistry-db-specialist  (chembl-database, pubchem-database, drugbank-database, zinc-database, bindingdb-database)
    │   ├─► genomics-db-specialist  (ensembl-database, gene-database, gnomad-database, geo-database, gtex-database, gwas-database)
    │   ├─► literature-db-specialist  (arxiv-database, biorxiv-database, openalex-database, pubmed-database)
    │   ├─► proteomics-db-specialist  (alphafold-database, pdb-database, uniprot-database, interpro-database, string-database)
    │   └─► regulatory-db-specialist  (fda-database, uspto-database, ena-database, jaspar-database, metabolomics-workbench-database, opentargets-database)
    ├─► drug-discovery-lead  (rdkit, datamol)
    │   ├─► cheminformatics-scientist  (rdkit, molfeat, medchem, datamol, deepchem)
    │   ├─► drug-screening-analyst  (pytdc, torchdrug, matchms, pyopenms)
    │   └─► molecular-docking-specialist  (diffdock, molecular-dynamics, rowan, esm)
    ├─► financial-research-lead  (edgartools, fred-economic-data)
    │   └─► quantitative-analyst  (alpha-vantage, hedgefundmonitor, usfiscaldata, denario)
    ├─► lab-ops-lead  (benchling-integration, open-notebook)
    │   ├─► lab-automation-engineer  (opentrons-integration, pylabrobot, ginkgo-cloud-lab, protocolsio-integration)
    │   └─► lab-informatics-specialist  (labarchive-integration, lamindb, dnanexus-integration, latchbio-integration, omero-integration, modal)
    ├─► ml-lead  (scikit-learn, pytorch-lightning)
    │   ├─► deep-learning-engineer  (pytorch-lightning, transformers, torch-geometric, umap-learn)
    │   ├─► forecasting-analyst  (timesfm-forecasting, statsmodels, vaex, scikit-learn)
    │   ├─► optimization-scientist  (pymoo, simpy, dask, polars)
    │   ├─► rl-engineer  (stable-baselines3, pufferlib, pytorch-lightning)
    │   └─► statistical-modeler  (pymc, statsmodels, scikit-survival, shap)
    ├─► physical-sciences-lead  (sympy, astropy)
    │   ├─► biochemistry-specialist  (cobrapy, glycoengineering, dhdna-profiler)
    │   ├─► computational-physicist  (fluidsim, sympy, matlab, astropy)
    │   ├─► materials-scientist  (pymatgen, cobrapy, glycoengineering)
    │   └─► quantum-computing-scientist  (qiskit, cirq, pennylane, qutip)
    ├─► research-methods-lead  (hypothesis-generation, scientific-brainstorming)
    │   ├─► critical-analysis-specialist  (scientific-critical-thinking, consciousness-council, what-if-oracle, scholar-evaluation)
    │   └─► hypothesis-engineer  (hypogenic, dhdna-profiler, hypothesis-generation, scientific-brainstorming)
    └─► sci-comm-lead  (scientific-writing, peer-review)
        ├─► document-specialist  (docx, pdf, xlsx, markitdown, paper-2-web, markdown-mermaid-writing)
        ├─► manuscript-writer  (scientific-writing, writing, latex-posters, venue-templates, citation-management)
        ├─► market-research-analyst  (market-research-reports, scientific-schematics, scholar-evaluation)
        ├─► presentation-designer  (scientific-slides, pptx, pptx-posters, generate-image, infographics)
        └─► research-intelligence-analyst  (bgpt-paper-search, literature-review, research-lookup, research-grants, pyzotero)
```

## Layout

| Path | Role |
|------|------|
| `team.rb` | wiring (run this) |
| `COMPANY.md` | upstream company manifest, verbatim |
| `agents/<name>/AGENTS.md` | upstream role definitions, verbatim |
| `agents/<name>/.brute/skills/` | each member's skills, verbatim |

## Usage

```sh
export ANTHROPIC_API_KEY=...

bundle exec ruby examples/ports/paperclip/kdense-science-lab/team.rb \
  "<task for the team>"
```
