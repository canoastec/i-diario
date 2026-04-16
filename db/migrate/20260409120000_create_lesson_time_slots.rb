class CreateLessonTimeSlots < ActiveRecord::Migration[5.0]
  def up
    create_table :lesson_time_slots do |t|
      t.integer :period, null: false
      t.integer :class_number, null: false
      t.string :start_time, limit: 5, null: false
      t.string :end_time, limit: 5, null: false
    end

    add_index :lesson_time_slots, [:period, :class_number], unique: true

    add_column :general_configurations, :faceschool_tolerance_minutes, :integer, default: 10

    execute <<-SQL.squish
      INSERT INTO lesson_time_slots (period, class_number, start_time, end_time) VALUES
        (1, 1, '08:00', '08:55'),
        (1, 2, '08:55', '09:50'),
        (1, 3, '10:10', '11:05'),
        (1, 4, '11:05', '12:00'),
        (2, 1, '13:10', '14:05'),
        (2, 2, '14:05', '15:00'),
        (2, 3, '15:20', '16:15'),
        (2, 4, '16:15', '17:10')
    SQL
  end

  def down
    drop_table :lesson_time_slots
    remove_column :general_configurations, :faceschool_tolerance_minutes
  end
end
