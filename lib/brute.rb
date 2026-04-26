# frozen_string_literal: true

require 'ruby_llm'
require 'timeout'
require 'logger'
require 'scampi/kernel_ext'
require 'colorize_extended'

# Brute — a coding agent built on ruby_llm
#
# Cross-cutting concerns are implemented as Rack-style middleware in a
# Pipeline that wraps every LLM call:
#
#   Tracing → Retry → Session → Tokens → Compaction → ToolErrors → DoomLoop → Reasoning → [LLM Call]
#
require 'brute/version'

module Brute
  LOGO = <<-LOGO
 .o8                                .             
"888                              .o8             
 888oooo.  oooo d8b oooo  oooo  .o888oo  .ooooo.  
 d88' `88b `888""8P `888  `888    888   d88' `88b 
 888   888  888      888   888    888   888ooo888 
 888   888  888      888   888    888 . 888    .o 
 `Y8bod8P' d888b     `V88V"V8P'   "888" `Y8bod8P' 
  LOGO

  def self.config
    @config ||= RubyLLM.configure do |config|
      # Anthropic
      config.anthropic_api_key = ENV['ANTHROPIC_API_KEY']
      config.anthropic_api_base = ENV['ANTHROPIC_API_BASE'] # Available in v1.13.0+ (optional custom Anthropic endpoint)
    
      # Azure
      config.azure_api_base = ENV['AZURE_API_BASE'] # Microsoft Foundry project endpoint
      config.azure_api_key = ENV['AZURE_API_KEY'] # use this or
      config.azure_ai_auth_token = ENV['AZURE_AI_AUTH_TOKEN'] # this
    
      # Bedrock
      config.bedrock_api_key = ENV['AWS_ACCESS_KEY_ID']
      config.bedrock_secret_key = ENV['AWS_SECRET_ACCESS_KEY']
      config.bedrock_region = ENV['AWS_REGION'] # Required for Bedrock
      config.bedrock_session_token = ENV['AWS_SESSION_TOKEN'] # For temporary credentials
    
      # DeepSeek
      config.deepseek_api_key = ENV['DEEPSEEK_API_KEY']
      config.deepseek_api_base = ENV['DEEPSEEK_API_BASE'] # Available in v1.13.0+ (optional custom DeepSeek endpoint)
    
      # Gemini
      config.gemini_api_key = ENV['GEMINI_API_KEY']
      config.gemini_api_base = ENV['GEMINI_API_BASE'] # Available in v1.9.0+ (optional API version override)
    
      # GPUStack
      config.gpustack_api_base = ENV['GPUSTACK_API_BASE']
      config.gpustack_api_key = ENV['GPUSTACK_API_KEY']
    
      # Mistral
      config.mistral_api_key = ENV['MISTRAL_API_KEY']
    
      # Ollama
      config.ollama_api_base = 'http://localhost:11434/v1'
      config.ollama_api_key = ENV['OLLAMA_API_KEY'] # Available in v1.13.0+ (optional for authenticated/remote Ollama endpoints)
    
      # OpenAI
      config.openai_api_key = ENV['OPENAI_API_KEY']
      config.openai_api_base = ENV['OPENAI_API_BASE'] # Optional custom OpenAI-compatible endpoint
    
      # OpenRouter
      config.openrouter_api_key = ENV['OPENROUTER_API_KEY']
      config.openrouter_api_base = ENV['OPENROUTER_API_BASE'] # Available in v1.13.0+ (optional custom OpenRouter endpoint)
    
      # Perplexity
      config.perplexity_api_key = ENV['PERPLEXITY_API_KEY']
    
      # Vertex AI
      config.vertexai_project_id = ENV['GOOGLE_CLOUD_PROJECT'] # Available in v1.7.0+
      config.vertexai_location = ENV['GOOGLE_CLOUD_LOCATION']
      config.vertexai_service_account_key = ENV['VERTEXAI_SERVICE_ACCOUNT_KEY'] # Optional: service account JSON key
    
      # xAI
      config.xai_api_key = ENV['XAI_API_KEY'] # Available in v1.11.0+
    end
  end

  def self.provider
    @provider ||= RubyLLM::Provider.resolve(:anthropic).new(self.config)
  end
  
  def self.provider=(p)
    @provider = RubyLLM::Provider.resolve(value.to_sym).new(self.config)
  end
end

Dir.glob("#{__dir__}/brute/**/*.rb").sort.each do |path|
  require path
end

