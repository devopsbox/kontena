class GridSecret
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :grid

  field :name, type: String
  field :encrypted_value, type: String, encrypted: true

  validates_presence_of :name, :encrypted_value
  validates_uniqueness_of :name, scope: [:grid_id]

  index({ grid_id: 1 })

  # @return [String]
  def to_path
    "#{self.grid.try(:name)}/#{self.name}"
  end
end