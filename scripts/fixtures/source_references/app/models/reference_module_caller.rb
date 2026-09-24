class ReferenceModuleCaller
  def call
    ReferenceEncryption.encrypt
    ReferenceOwnership.generate
  end

  def namespace_value
    ReferenceNamespaceOnly::VALUE
  end
end
